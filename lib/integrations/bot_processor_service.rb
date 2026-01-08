class Integrations::BotProcessorService
  pattr_initialize [:event_name!, :hook!, :event_data!]

  def perform
    message = event_data[:message]
    return unless should_run_processor?(message)

    process_content(message)
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: (hook&.account || agent_bot&.account)).capture_exception
  end

  private

  def should_run_processor?(message)
    return if message.private?
    return unless processable_message?(message)
    return unless conversation.pending?
    return if should_defer_to_greeting?(message)

    true
  end

  def conversation
    message = event_data[:message]
    @conversation ||= message.conversation
  end

  def process_content(message)
    content = message_content(message)
    response = get_response(conversation.contact_inbox.source_id, content) if content.present?
    process_response(message, response) if response.present?
  end

  def message_content(message)
    # TODO: might needs to change this to a way that we fetch the updated value from event data instead
    # cause the message.updated event could be that that the message was deleted

    return message.content_attributes['submitted_values']&.first&.dig('value') if event_name == 'message.updated'

    message.content
  end

  def processable_message?(message)
    # TODO: change from reportable and create a dedicated method for this?
    return unless message.reportable?
    return if message.outgoing? && !processable_outgoing_message?(message)

    true
  end

  def processable_outgoing_message?(message)
    event_name == 'message.updated' && ['input_select'].include?(message.content_type)
  end

  def process_action(message, action)
    case action
    when 'handoff'
      message.conversation.bot_handoff!
    when 'resolve'
      message.conversation.resolved!
    end
  end

  def should_defer_to_greeting?(message)
    # Skip bot processing if this is the first contact message and greeting is enabled
    # This allows the channel greeting to send first, then bot takes over on subsequent messages
    return false unless message.incoming?

    inbox = conversation.inbox
    return false unless inbox.greeting_enabled? && inbox.greeting_message.present?

    # Check if this is first message from contact (same logic as MessageTemplates::HookExecutionService)
    first_message_from_contact?
  end

  def first_message_from_contact?
    conversation.messages.outgoing.count.zero? && conversation.messages.template.count.zero?
  end
end
