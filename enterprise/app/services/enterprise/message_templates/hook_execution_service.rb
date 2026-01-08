module Enterprise::MessageTemplates::HookExecutionService
  MAX_ATTACHMENT_WAIT_SECONDS = 4

  def trigger_templates
    # Must check BEFORE super, because super creates the greeting template message
    # which would make first_message_from_contact? return false
    defer_to_greeting = should_defer_to_greeting?

    super
    return unless should_process_captain_response?
    return perform_handoff unless inbox.captain_active?
    return if defer_to_greeting

    schedule_captain_response
  end

  def should_send_out_of_office_message?
    return false if captain_handling_conversation?

    super
  end

  def should_send_email_collect?
    return false if captain_handling_conversation?

    super
  end

  private

  def schedule_captain_response
    # Pass message timestamp for proper debouncing on buffered channels
    job_args = [conversation, conversation.inbox.captain_assistant, message.created_at]
    wait_time = calculate_captain_response_wait_time

    if wait_time.zero?
      Captain::Conversation::ResponseBuilderJob.perform_later(*job_args)
    else
      Captain::Conversation::ResponseBuilderJob.set(wait: wait_time).perform_later(*job_args)
    end
  end

  def calculate_captain_response_wait_time
    base_wait = buffered_response_channel? ? 3.seconds : 0.seconds
    attachment_wait = message.attachments.present? ? calculate_attachment_wait_time : 0.seconds
    base_wait + attachment_wait
  end

  def buffered_response_channel?
    inbox.whatsapp? || inbox.instagram?
  end

  def calculate_attachment_wait_time
    attachment_count = message.attachments.size
    base_wait = 1.second

    # Wait longer for more attachments or larger files
    additional_wait = [attachment_count * 1, MAX_ATTACHMENT_WAIT_SECONDS].min.seconds
    base_wait + additional_wait
  end

  def should_process_captain_response?
    conversation.pending? && message.incoming? && inbox.captain_assistant.present?
  end

  def perform_handoff
    return unless conversation.pending?

    Rails.logger.info("Captain limit exceeded, performing handoff mid-conversation for conversation: #{conversation.id}")
    conversation.messages.create!(
      message_type: :outgoing,
      account_id: conversation.account.id,
      inbox_id: conversation.inbox.id,
      content: 'Transferring to another agent for further assistance.'
    )
    conversation.bot_handoff!
    send_out_of_office_message_after_handoff
  end

  def send_out_of_office_message_after_handoff
    ::MessageTemplates::Template::OutOfOffice.perform_if_applicable(conversation)
  end

  def should_defer_to_greeting?
    # Skip Captain on first message when greeting is enabled
    # The greeting takes precedence, Captain will respond to subsequent messages
    return false unless inbox.greeting_enabled? && inbox.greeting_message.present?

    first_message_from_contact?
  end

  def captain_handling_conversation?
    conversation.pending? && inbox.respond_to?(:captain_assistant) && inbox.captain_assistant.present?
  end
end
