class Captain::Tools::GetCalComAvailableSlotTool < Captain::Tools::BasePublicTool
  include Captain::Tools::Concerns::CalComHelpers

  def self.available?(account)
    account.hooks.find_by(app_id: 'cal_com')&.enabled?
  end

  description 'Get available time slots from Cal.com for scheduling appointments'
  param :event_type_id,
        type: 'string',
        desc: 'The Cal.com event type ID to check availability for (required)'
  param :start_time,
        type: 'string',
        desc: 'Start of the search range in ISO 8601 format (e.g., 2026-01-10T00:00:00Z)'
  param :end_time,
        type: 'string',
        desc: 'End of the search range in ISO 8601 format (e.g., 2026-01-13T00:00:00Z)'
  param :timezone,
        type: 'string',
        desc: "Optional IANA timezone (e.g., 'America/Chicago'). Defaults to Cal.com user's timezone or UTC.",
        required: false

  def perform(tool_context, event_type_id:, start_time:, end_time:, timezone: nil)
    conversation = find_conversation(tool_context.state)
    return { error: 'Conversation not found' }.to_json unless conversation

    hook = find_calcom_hook(conversation)
    return { error: 'Cal.com integration not connected' }.to_json unless hook&.enabled?

    api_key = get_calcom_api_key(hook)
    return { error: 'Cal.com API key not found' }.to_json if api_key.blank?

    # Determine timezone - use provided, fetch from Cal.com, or default to UTC
    target_timezone = determine_timezone(timezone, conversation)

    # Build query parameters
    query_params = build_query_params(event_type_id, start_time, end_time, target_timezone)

    # Fetch available slots from Cal.com API
    result = fetch_available_slots(api_key, query_params)

    log_tool_usage('get_cal_com_available_slots', {
                     conversation_id: conversation.id,
                     event_type_id: event_type_id,
                     start_time: start_time,
                     end_time: end_time,
                     timezone: target_timezone
                   })

    result.to_json
  rescue ArgumentError => e
    { error: e.message }.to_json
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    { error: "Error fetching available slots: #{e.message}" }.to_json
  end

  private

  def determine_timezone(timezone, conversation)
    return timezone if timezone.present?

    calcom_timezone = get_calcom_timezone(conversation)
    return calcom_timezone if calcom_timezone.present?

    'UTC'
  end

  def build_query_params(event_type_id, start_time, end_time, timezone)
    {
      eventTypeId: event_type_id,
      start: start_time,
      end: end_time,
      timeZone: timezone
    }
  end

  def fetch_available_slots(api_key, query_params)
    # Build the query string
    query_string = URI.encode_www_form(query_params)
    path = "/slots?#{query_string}"

    response = calcom_api_request(:get, path, api_key, nil, '2024-09-04')

    if response[:success]
      data = response[:data]['data']
      format_slots_response(data, query_params[:timeZone])
    else
      { error: response[:error] || 'Failed to fetch available slots' }
    end
  end

  def format_slots_response(slots_data, timezone)
    # slots_data is a hash with dates as keys and arrays of slot objects as values
    # Example: { "2026-01-10" => [{ "start" => "2026-01-10T09:00:00.000-06:00" }, ...] }

    total_slots = 0
    formatted_dates = {}

    slots_data&.each do |date, slots|
      formatted_slots = slots.map { |slot| slot['start'] }
      formatted_dates[date] = formatted_slots
      total_slots += formatted_slots.length
    end

    {
      timezone: timezone,
      total_available_slots: total_slots,
      available_dates: formatted_dates.keys,
      slots_by_date: formatted_dates
    }
  end
end
