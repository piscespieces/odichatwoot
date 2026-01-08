class Captain::Tools::CreateCalendarEventTool < Captain::Tools::BasePublicTool
  def self.available?(account)
    account.hooks.find_by(app_id: 'google_calendar')&.enabled?
  end

  description 'Create a new event in Google Calendar'
  param :title, type: 'string', desc: 'Title of the event'
  param :start_time, type: 'string', desc: 'Start time (ISO 8601)'
  param :end_time, type: 'string', desc: 'End time (ISO 8601)'
  param :description, type: 'string', desc: 'Description of the event', required: false
  param :additional_details, type: 'object', desc: 'Industry-specific data collected (e.g., insurance, reason for visit, case ID)', required: false

  # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
  def perform(tool_context, title:, start_time:, end_time:, description: nil, attendee_email: nil, additional_details: nil)
    conversation = find_conversation(tool_context.state)
    return 'Conversation not found' unless conversation

    # Ensure Google Calendar is connected
    hook = conversation.account.hooks.find_by(app_id: 'google_calendar')
    return 'Google Calendar integration not connected' unless hook&.enabled?

    token = GoogleCalendar::RefreshOauthTokenService.new(hook: hook).access_token
    return 'Failed to obtain access token' if token.blank?

    result = create_google_calendar_event(token, title, start_time, end_time, description, attendee_email, additional_details)

    log_tool_usage('create_event', {
                     conversation_id: conversation.id,
                     title: title,
                     status: result[:status]
                   })

    if result[:status] == 'success'
      "Calendar event created: #{title}. Link: #{result[:link]}"
    else
      "Failed to create event: #{result[:error]}"
    end
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    "Error creating calendar event: #{e.message}"
  end
  # rubocop:enable Metrics/ParameterLists, Metrics/MethodLength

  private

  # rubocop:disable Metrics/ParameterLists, Metrics/MethodLength
  def create_google_calendar_event(token, title, start_time, end_time, description, attendee_email, additional_details)
    uri = URI('https://www.googleapis.com/calendar/v3/calendars/primary/events')
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    request = Net::HTTP::Post.new(uri.path)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'

    final_description = format_description(description, additional_details)

    body = {
      summary: title,
      description: final_description,
      start: { dateTime: start_time },
      end: { dateTime: end_time }
    }
    body[:attendees] = [{ email: attendee_email }] if attendee_email.present?

    request.body = body.to_json
    response = http.request(request)
    data = JSON.parse(response.body)

    if response.is_a?(Net::HTTPSuccess)
      { status: 'success', link: data['htmlLink'] }
    else
      { status: 'error', error: data.dig('error', 'message') || 'Unknown error' }
    end
  end
  # rubocop:enable Metrics/ParameterLists, Metrics/MethodLength

  def format_description(base_description, additional_details)
    return base_description if additional_details.blank?

    header = "--- APPOINTMENT DETAILS ---\n"
    additional_details.each do |key, value|
      header += "#{key.to_s.humanize}: #{value}\n"
    end
    header += "---------------------------\n\n"

    "#{header}#{base_description}"
  end
end
