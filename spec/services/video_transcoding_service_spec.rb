# frozen_string_literal: true

require 'rails_helper'

RSpec.describe VideoTranscodingService do
  describe '#perform' do
    let(:mov_file) do
      file = Tempfile.new(['test_video', '.mov'])
      file.binmode
      # Create a minimal file header (just enough for the test structure)
      file.write("moov\x00\x00\x00\x00")
      file.rewind
      file.define_singleton_method(:original_filename) { 'video.MOV' }
      file.define_singleton_method(:content_type) { 'video/quicktime' }
      file
    end

    let(:mp4_file) do
      file = Tempfile.new(['test_video', '.mp4'])
      file.binmode
      file.write("\x00\x00\x00\x18ftypmp42")
      file.rewind
      file.define_singleton_method(:original_filename) { 'video.mp4' }
      file.define_singleton_method(:content_type) { 'video/mp4' }
      file
    end

    after do
      mov_file.close
      mov_file.unlink
      mp4_file.close
      mp4_file.unlink
    end

    context 'when file is MOV format' do
      subject(:service) { described_class.new(mov_file, content_type: 'video/quicktime') }

      it 'identifies the file as needing transcoding' do
        expect(service.needs_transcoding?).to be true
      end

      # Integration test - requires FFmpeg to be installed
      context 'with FFmpeg available', :ffmpeg do
        it 'transcodes MOV to MP4' do
          # This test would require a real MOV file and FFmpeg installed
          # Skip if FFmpeg is not available
          skip 'FFmpeg not installed' unless ffmpeg_available?

          result = service.perform
          expect(result[:transcoded]).to be true
          expect(result[:content_type]).to eq('video/mp4')
          expect(result[:filename]).to end_with('.mp4')
        end
      end

      context 'when FFmpeg is not available' do
        before do
          allow(FFMPEG).to receive(:ffmpeg_binary).and_return(nil)
        end

        it 'returns the original file on error' do
          result = service.perform
          expect(result[:transcoded]).to be false
          expect(result[:file]).to eq(mov_file)
        end
      end
    end

    context 'when file is already MP4 format' do
      subject(:service) { described_class.new(mp4_file, content_type: 'video/mp4') }

      it 'does not need transcoding' do
        expect(service.needs_transcoding?).to be false
      end

      it 'returns the original file unchanged' do
        result = service.perform
        expect(result[:transcoded]).to be false
        expect(result[:file]).to eq(mp4_file)
        expect(result[:content_type]).to eq('video/mp4')
      end
    end

    context 'when file is video/x-quicktime format' do
      subject(:service) { described_class.new(mov_file, content_type: 'video/x-quicktime') }

      it 'identifies the file as needing transcoding' do
        expect(service.needs_transcoding?).to be true
      end
    end

    context 'when content_type is nil' do
      subject(:service) { described_class.new(file_without_content_type, content_type: nil) }

      let(:file_without_content_type) do
        file = Tempfile.new(['test_video', '.mov'])
        file.binmode
        file.write("moov\x00\x00\x00\x00")
        file.rewind
        file.define_singleton_method(:original_filename) { 'video.mov' }
        file
      end

      after do
        file_without_content_type.close
        file_without_content_type.unlink
      end

      it 'does not need transcoding when content type is nil' do
        expect(service.needs_transcoding?).to be false
      end
    end
  end

  def ffmpeg_available?
    FFMPEG.ffmpeg_binary && File.executable?(FFMPEG.ffmpeg_binary)
  rescue StandardError
    false
  end
end
