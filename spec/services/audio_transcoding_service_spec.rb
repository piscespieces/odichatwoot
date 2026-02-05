# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AudioTranscodingService do
  describe '#perform' do
    let(:ogg_file) do
      file = Tempfile.new(['test_audio', '.ogg'])
      file.binmode
      # Create a minimal valid OGG file header (just enough for the test)
      file.write("OggS\x00\x02")
      file.rewind
      file.define_singleton_method(:original_filename) { 'voice_note.ogg' }
      file.define_singleton_method(:content_type) { 'audio/ogg' }
      file
    end

    let(:mp3_file) do
      file = Tempfile.new(['test_audio', '.mp3'])
      file.binmode
      file.write("\xFF\xFB\x90\x00") # MP3 header
      file.rewind
      file.define_singleton_method(:original_filename) { 'audio.mp3' }
      file.define_singleton_method(:content_type) { 'audio/mpeg' }
      file
    end

    after do
      ogg_file.close
      ogg_file.unlink
      mp3_file.close
      mp3_file.unlink
    end

    context 'when file is OGG format' do
      subject(:service) { described_class.new(ogg_file, content_type: 'audio/ogg') }

      it 'identifies the file as needing transcoding' do
        expect(service.needs_transcoding?).to be true
      end

      # Integration test - requires FFmpeg to be installed
      context 'with FFmpeg available', :ffmpeg do
        it 'transcodes OGG to MP3' do
          # This test would require a real OGG file and FFmpeg installed
          # Skip if FFmpeg is not available
          skip 'FFmpeg not installed' unless ffmpeg_available?

          result = service.perform
          expect(result[:transcoded]).to be true
          expect(result[:content_type]).to eq('audio/mpeg')
          expect(result[:filename]).to end_with('.mp3')
        end
      end

      context 'when FFmpeg is not available' do
        before do
          allow(FFMPEG).to receive(:ffmpeg_binary).and_return(nil)
        end

        it 'returns the original file on error' do
          result = service.perform
          expect(result[:transcoded]).to be false
          expect(result[:file]).to eq(ogg_file)
        end
      end
    end

    context 'when file is already MP3 format' do
      subject(:service) { described_class.new(mp3_file, content_type: 'audio/mpeg') }

      it 'does not need transcoding' do
        expect(service.needs_transcoding?).to be false
      end

      it 'returns the original file unchanged' do
        result = service.perform
        expect(result[:transcoded]).to be false
        expect(result[:file]).to eq(mp3_file)
        expect(result[:content_type]).to eq('audio/mpeg')
      end
    end

    context 'when file is Opus format' do
      subject(:service) { described_class.new(ogg_file, content_type: 'audio/opus') }

      it 'identifies the file as needing transcoding' do
        expect(service.needs_transcoding?).to be true
      end
    end

    context 'when content_type is application/ogg' do
      subject(:service) { described_class.new(ogg_file, content_type: 'application/ogg') }

      it 'identifies the file as needing transcoding' do
        expect(service.needs_transcoding?).to be true
      end
    end
  end

  def ffmpeg_available?
    FFMPEG.ffmpeg_binary && File.executable?(FFMPEG.ffmpeg_binary)
  rescue StandardError
    false
  end
end
