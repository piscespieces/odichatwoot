class Captain::Tools::GetCurrentCalComTimeTool < Captain::Tools::BasePublicTool
  include Captain::Tools::Concerns::CalComHelpers

  def self.available?(account)
    account.hooks.find_by(app_id: 'cal_com')&.enabled?
  end

  description 'Get the current time in ISO 8601 format using the Cal.com account timezone'
  param :timezone,
        type: 'string',
        desc: "Optional IANA timezone (e.g., 'America/Los_Angeles', 'Europe/London', 'UTC'). " \
              "If not provided, uses the Cal.com user's default timezone.",
        required: false

  def perform(tool_context, timezone: nil)
    target_timezone = timezone

    conversation = find_conversation(tool_context.state)

    # If no timezone provided, fetch from Cal.com user profile
    target_timezone = get_calcom_timezone(conversation) if target_timezone.blank? && conversation

    # Fallback to system timezone
    target_timezone = Time.now.zone if target_timezone.blank?

    current_time = format_current_time(target_timezone)

    log_tool_usage('get_current_calcom_time', {
                     conversation_id: conversation&.id,
                     timezone: target_timezone
                   })

    {
      current_time: current_time.iso8601,
      current_year: current_time.year,
      current_month: current_time.month,
      current_day: current_time.day,
      current_day_of_week: current_time.strftime('%A'),
      timezone: target_timezone
    }.to_json
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    { error: "Error getting current time: #{e.message}" }.to_json
  end

  private

  def format_current_time(timezone)
    # Attempt to find the timezone object
    # 1. Try ActiveSupport::TimeZone
    zone = ActiveSupport::TimeZone[timezone] if timezone.present?

    return Time.now.in_time_zone(zone) if zone

    # Fallback to UTC if timezone is invalid
    Time.now.utc
  end
end
