class Captain::Tools::CreateCalComBookingTool < Captain::Tools::BasePublicTool
  include Captain::Tools::Concerns::CalComHelpers

  def self.available?(account)
    account.hooks.find_by(app_id: 'cal_com')&.enabled?
  end

  description 'Create a booking/appointment in Cal.com'
  param :event_type_id,
        type: 'string',
        desc: 'The Cal.com event type ID to book'
  param :start_time,
        type: 'string',
        desc: 'Start time in UTC ISO 8601 format (e.g., 2026-01-10T09:00:00Z). Must be in UTC.'
  param :attendee_name,
        type: 'string',
        desc: 'Full name of the attendee'
  param :attendee_email,
        type: 'string',
        desc: 'Email address of the attendee'
  param :attendee_timezone,
        type: 'string',
        desc: "Attendee's IANA timezone (e.g., 'America/Chicago')"
  param :attendee_phone,
        type: 'string',
        desc: "Attendee's phone number in international format (e.g., +19876543210)",
        required: false
  param :attendee_language,
        type: 'string',
        desc: "Attendee's preferred language code (e.g., 'en', 'es')",
        required: false
  param :notes,
        type: 'string',
        desc: 'Additional context, notes, or intake form responses to be included in the booking details',
        required: false

  # rubocop:disable Metrics/ParameterLists
  def perform(tool_context, event_type_id:, start_time:, attendee_name:, attendee_email:, attendee_timezone:,
              attendee_phone: nil, attendee_language: 'en', notes: nil)
    conversation = find_conversation(tool_context.state)
    return { error: 'Conversation not found' }.to_json unless conversation

    hook = find_calcom_hook(conversation)
    return { error: 'Cal.com integration not connected' }.to_json unless hook&.enabled?

    api_key = get_calcom_api_key(hook)
    return { error: 'Cal.com API key not found' }.to_json if api_key.blank?

    # Build the booking request body
    booking_body = build_booking_body(
      event_type_id: event_type_id,
      start_time: start_time,
      attendee_name: attendee_name,
      attendee_email: attendee_email,
      attendee_timezone: attendee_timezone,
      attendee_phone: attendee_phone,
      attendee_language: attendee_language,
      notes: notes
    )

    # Create the booking via Cal.com API
    result = create_booking(api_key, booking_body)

    log_tool_usage('create_cal_com_booking', {
                     conversation_id: conversation.id,
                     event_type_id: event_type_id,
                     start_time: start_time,
                     attendee_email: attendee_email,
                     status: result.dig(:booking, :status) || 'unknown'
                   })

    result.to_json
  rescue ArgumentError => e
    { error: e.message }.to_json
  rescue StandardError => e
    ChatwootExceptionTracker.new(e).capture_exception
    { error: "Error creating booking: #{e.message}" }.to_json
  end
  # rubocop:enable Metrics/ParameterLists

  private

  def build_booking_body(event_type_id:, start_time:, attendee_name:, attendee_email:,
                         attendee_timezone:, attendee_phone:, attendee_language:, notes: nil)
    body = {
      eventTypeId: event_type_id.to_i,
      start: start_time,
      attendee: {
        name: attendee_name,
        email: attendee_email,
        timeZone: attendee_timezone,
        language: attendee_language || 'en'
      },
      bookingFieldsResponses: {
        notes: notes
      }
    }

    # Add phone number if provided (required for SMS reminders)
    body[:attendee][:phoneNumber] = attendee_phone if attendee_phone.present?

    body
  end

  def create_booking(api_key, booking_body)
    response = calcom_api_request(:post, '/bookings', api_key, booking_body, '2024-08-13')

    if response[:success]
      format_booking_response(response[:data]['data'])
    else
      { error: response[:error] || 'Failed to create booking' }
    end
  end

  def format_booking_response(booking_data)
    {
      booking: {
        id: booking_data['id'],
        uid: booking_data['uid'],
        title: booking_data['title'],
        status: booking_data['status'],
        start: booking_data['start'],
        end: booking_data['end'],
        duration: booking_data['duration'],
        meeting_url: booking_data['meetingUrl'],
        location: booking_data['location'],
        event_type_id: booking_data['eventTypeId'],
        hosts: booking_data['hosts']&.map { |h| { name: h['name'], email: h['email'] } },
        attendees: booking_data['attendees']&.map do |a|
          { name: a['name'], email: a['email'], timezone: a['timeZone'] }
        end
      }
    }
  end
end
