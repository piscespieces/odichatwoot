require 'time'

class Captain::Tools::GetFreeBusyCalendarTool < Captain::Tools::BasePublicTool
  include Captain::Tools::Concerns::GoogleCalendarHelpers

  def self.available?(account)
    account.hooks.find_by(app_id: 'google_calendar')&.enabled?
  end

  description "Query Google's free/busy endpoint to get a list of busy time blocks for a specific calendar."
  param :calendar_id,
        type: 'string',
        desc: 'The Google Calendar ID to query (e.g., "primary" or a specific email address).'
  param :time_min,
        type: 'string',
        desc: 'The start of the interval for the query (must be in ISO 8601 format).'
  param :time_max,
        type: 'string',
        desc: 'The end of the interval for the query (must be in ISO 8601 format).'
  param :timezone,
        type: 'string',
        desc: 'Timezone for the query',
        required: false

  # rubocop:disable Metrics/MethodLength
  def perform(tool_context, calendar_id:, time_min:, time_max:, timezone: nil)
    puts "[GetFreeBusyCalendarTool] perform called with calendar_id=#{calendar_id}, time_min=#{time_min}, time_max=#{time_max}, timezone=#{timezone}"

    conversation = find_conversation(tool_context.state)
    puts "[GetFreeBusyCalendarTool] conversation found: #{conversation&.id}"
    validate_conversation!(conversation)

    hook = conversation.account.hooks.find_by(app_id: 'google_calendar')
    puts "[GetFreeBusyCalendarTool] hook found: id=#{hook&.id}, enabled=#{hook&.enabled?}"
    validate_hook!(hook)
    validate_time_range!(time_min, time_max)
    puts '[GetFreeBusyCalendarTool] time range validated'

    target_timezone = determine_timezone(timezone, conversation)
    puts "[GetFreeBusyCalendarTool] target_timezone=#{target_timezone}"

    puts '[GetFreeBusyCalendarTool] calling retrieve_access_token...'
    token = retrieve_access_token(hook)
    puts "[GetFreeBusyCalendarTool] token retrieved: #{token&.first(20)}..."

    puts '[GetFreeBusyCalendarTool] calling fetch_free_busy...'
    result = fetch_free_busy(token, calendar_id, time_min, time_max, target_timezone)
    puts "[GetFreeBusyCalendarTool] fetch_free_busy result: #{result}"

    log_tool_usage('get_free_busy', {
                     conversation_id: conversation.id,
                     calendar_id: calendar_id,
                     time_min: time_min,
                     time_max: time_max
                   })

    result
  rescue ArgumentError => e
    puts "[GetFreeBusyCalendarTool] ArgumentError: #{e.message}"
    puts "[GetFreeBusyCalendarTool] Backtrace: #{e.backtrace&.first(5)&.join("\n")}"
    { error: e.message }.to_json
  rescue StandardError => e
    puts "[GetFreeBusyCalendarTool] StandardError: #{e.class} - #{e.message}"
    puts "[GetFreeBusyCalendarTool] Backtrace: #{e.backtrace&.first(5)&.join("\n")}"
    ChatwootExceptionTracker.new(e).capture_exception
    { error: "Error executing free/busy tool: #{e.message}" }.to_json
  end
  # rubocop:enable Metrics/MethodLength

  private

  def validate_conversation!(conversation)
    raise ArgumentError, 'Conversation not found' unless conversation
  end

  def validate_hook!(hook)
    raise ArgumentError, 'Google Calendar integration not connected' unless hook&.enabled?
  end

  def validate_time_range!(time_min, time_max)
    return if less_than_three_months?(time_min, time_max)

    raise ArgumentError, 'The time gap between time_min and time_max cannot be greater than 3 months.'
  end

  def determine_timezone(timezone, conversation)
    return timezone if timezone.present?

    calendar_timezone = get_calendar_timezone(conversation)
    return calendar_timezone if calendar_timezone.present?

    'UTC'
  end

  def retrieve_access_token(hook)
    puts "[GetFreeBusyCalendarTool] retrieve_access_token: creating RefreshOauthTokenService for hook_id=#{hook.id}"
    token = GoogleCalendar::RefreshOauthTokenService.new(hook: hook).access_token
    puts "[GetFreeBusyCalendarTool] retrieve_access_token: token returned=#{token&.first(20) || 'NIL'}..."

    if token.blank?
      puts '[GetFreeBusyCalendarTool] retrieve_access_token: token is BLANK, raising ArgumentError'
      raise ArgumentError, 'Failed to obtain access token'
    end

    token
  end

  def less_than_three_months?(time_min, time_max)
    # Parse strings into Time objects
    # iso8601 raises ArgumentError if format is invalid
    min_date = Time.iso8601(time_min)
    max_date = Time.iso8601(time_max)

    # Ensure range is positive (non-backward)
    return false if max_date <= min_date

    # Calculate difference in seconds
    # 3 months is approximately 90 days
    diff_in_seconds = max_date - min_date
    three_months_in_seconds = 90 * 24 * 60 * 60

    diff_in_seconds <= three_months_in_seconds
  rescue ArgumentError, TypeError => e
    # Returns error if strings are malformed or nil
    raise ArgumentError, "Invalid date format: #{e.message}"
  end

  def fetch_free_busy(token, calendar_id, time_min, time_max, timezone)
    uri = URI('https://www.googleapis.com/calendar/v3/freeBusy')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.path)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'

    body = {
      timeMin: time_min,
      timeMax: time_max,
      timeZone: timezone,
      items: [{ id: calendar_id }]
    }

    request.body = body.to_json
    response = http.request(request)
    data = JSON.parse(response.body)

    if response.is_a?(Net::HTTPSuccess)
      {
        time_min: data['timeMin'],
        time_max: data['timeMax'],
        calendars: data['calendars']
      }.to_json
    else
      { error: data.dig('error', 'message') || 'Unknown error' }.to_json
    end
  end
end
