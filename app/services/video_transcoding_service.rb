# frozen_string_literal: true

# Service to transcode video files from MOV/QuickTime to MP4 format
# for WhatsApp API compatibility (WhatsApp only accepts video/mp4 and video/3gpp)
class VideoTranscodingService
  SUPPORTED_INPUT_FORMATS = %w[video/quicktime video/x-quicktime].freeze
  OUTPUT_FORMAT = 'mp4'
  OUTPUT_CONTENT_TYPE = 'video/mp4'

  class TranscodingError < StandardError; end

  def initialize(file, content_type: nil)
    @file = file
    @content_type = content_type || detect_content_type
  end

  # Returns a hash with transcoded file info, or original file if no transcoding needed
  # @return [Hash] { file: IO, filename: String, content_type: String, transcoded: Boolean }
  def perform
    return original_file_result unless needs_transcoding?

    transcode_to_mp4
  rescue StandardError => e
    Rails.logger.error "Video transcoding failed: #{e.message}"
    # Return original file on error - let WhatsApp reject it with a clear error
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

  def transcode_to_mp4
    ensure_ffmpeg_available!

    input_path = create_temp_input_file
    output_path = generate_output_path

    begin
      movie = FFMPEG::Movie.new(input_path)
      raise TranscodingError, 'Invalid video file' unless movie.valid?

      # Transcode to MP4 with H.264 video and AAC audio for maximum compatibility
      # -movflags faststart: Moves moov atom to the beginning for web streaming
      # Using 'baseline' profile for broader device compatibility
      transcoding_options = {
        video_codec: 'libx264',
        audio_codec: 'aac',
        custom: %w[-profile:v baseline -level 3.0 -movflags +faststart -pix_fmt yuv420p]
      }

      movie.transcode(output_path, transcoding_options)

      output_file = File.open(output_path, 'rb')

      {
        file: output_file,
        filename: mp4_filename,
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
    temp_file = Tempfile.new(['video_input', input_extension])
    temp_file.binmode

    @file.rewind if @file.respond_to?(:rewind)
    IO.copy_stream(@file, temp_file)
    temp_file.close

    temp_file.path
  end

  def generate_output_path
    temp_file = Tempfile.new(['video_output', '.mp4'])
    path = temp_file.path
    temp_file.close
    temp_file.unlink
    path
  end

  def input_extension
    '.mov'
  end

  def original_filename
    if @file.respond_to?(:original_filename)
      @file.original_filename
    else
      "video#{input_extension}"
    end
  end

  def mp4_filename
    base = File.basename(original_filename, '.*')
    "#{base}.mp4"
  end

  def detect_content_type
    return @file.content_type if @file.respond_to?(:content_type)

    nil
  end
end
