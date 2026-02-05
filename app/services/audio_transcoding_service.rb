# frozen_string_literal: true

# Service to transcode audio files from OGG/Opus to MP3 format
# for better browser compatibility (Safari/iOS doesn't support OGG/Opus natively)
class AudioTranscodingService
  SUPPORTED_INPUT_FORMATS = %w[audio/ogg application/ogg audio/opus].freeze
  OUTPUT_FORMAT = 'mp3'
  OUTPUT_CONTENT_TYPE = 'audio/mpeg'

  class TranscodingError < StandardError; end

  def initialize(file, content_type: nil)
    @file = file
    @content_type = content_type || detect_content_type
  end

  # Returns a hash with transcoded file info, or original file if no transcoding needed
  # @return [Hash] { file: IO, filename: String, content_type: String, transcoded: Boolean }
  def perform
    return original_file_result unless needs_transcoding?

    transcode_to_mp3
  rescue StandardError => e
    Rails.logger.error "Audio transcoding failed: #{e.message}"
    # Return original file on error - better to have OGG than nothing
    original_file_result
  end

  def needs_transcoding?
    SUPPORTED_INPUT_FORMATS.include?(@content_type&.downcase)
  end

  private

  def original_file_result
    {
      file: @file,
      filename: original_filename,
      content_type: @content_type,
      transcoded: false
    }
  end

  def transcode_to_mp3
    ensure_ffmpeg_available!

    input_path = create_temp_input_file
    output_path = generate_output_path

    begin
      movie = FFMPEG::Movie.new(input_path)
      raise TranscodingError, 'Invalid audio file' unless movie.valid?

      # Transcode to MP3 with reasonable quality settings
      movie.transcode(output_path, audio_codec: 'libmp3lame', audio_bitrate: 128)

      output_file = File.open(output_path, 'rb')

      {
        file: output_file,
        filename: mp3_filename,
        content_type: OUTPUT_CONTENT_TYPE,
        transcoded: true
      }
    ensure
      FileUtils.rm_f(input_path)
      # NOTE: output_path file will be cleaned up by the caller or garbage collection
    end
  end

  def ensure_ffmpeg_available!
    raise TranscodingError, 'FFmpeg not available' unless FFMPEG.ffmpeg_binary && File.executable?(FFMPEG.ffmpeg_binary)
  end

  def create_temp_input_file
    temp_file = Tempfile.new(['audio_input', input_extension])
    temp_file.binmode

    @file.rewind if @file.respond_to?(:rewind)
    IO.copy_stream(@file, temp_file)
    temp_file.close

    temp_file.path
  end

  def generate_output_path
    temp_file = Tempfile.new(['audio_output', '.mp3'])
    path = temp_file.path
    temp_file.close
    temp_file.unlink
    path
  end

  def input_extension
    case @content_type&.downcase
    when 'audio/opus'
      '.opus'
    else
      '.ogg'
    end
  end

  def original_filename
    if @file.respond_to?(:original_filename)
      @file.original_filename
    else
      "audio#{input_extension}"
    end
  end

  def mp3_filename
    base = File.basename(original_filename, '.*')
    "#{base}.mp3"
  end

  def detect_content_type
    return @file.content_type if @file.respond_to?(:content_type)

    nil
  end
end
