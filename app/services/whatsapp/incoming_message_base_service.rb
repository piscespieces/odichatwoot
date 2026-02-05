# Mostly modeled after the intial implementation of the service based on 360 Dialog
# https://docs.360dialog.com/whatsapp-api/whatsapp-api/media
# https://developers.facebook.com/docs/whatsapp/api/media/
class Whatsapp::IncomingMessageBaseService
  include ::Whatsapp::IncomingMessageServiceHelpers
  include ::Whatsapp::IncomingMessageCoexistenceHelpers

  pattr_initialize [:inbox!, :params!]

  def perform
    processed_params

    if processed_params.try(:[], :statuses).present?
      process_statuses
    elsif processed_params.try(:[], :messages).present?
      process_messages
    elsif processed_params.try(:[], :message_echoes).present?
      # WhatsApp Coexistence: Handle messages sent from WhatsApp Business App
      # These arrive with the key 'message_echoes' instead of 'messages'
      process_message_echoes
    end
  end

  private

  def process_messages
    # We don't support reactions & ephemeral message now, we need to skip processing the message
    # if the webhook event is a reaction or an ephermal message or an unsupported message.
    return if unprocessable_message_type?(message_type)

    # Multiple webhook event can be received against the same message due to misconfigurations in the Meta
    # business manager account. While we have not found the core reason yet, the following line ensure that
    # there are no duplicate messages created.
    return if find_message_by_source_id(@processed_params[:messages].first[:id]) || message_under_process?

    cache_message_source_id_in_redis
    set_contact
    return unless @contact

    ActiveRecord::Base.transaction do
      set_conversation
      create_messages
      clear_message_source_id_from_redis
    end
  end

  def process_statuses
    return unless find_message_by_source_id(@processed_params[:statuses].first[:id])

    update_message_with_status(@message, @processed_params[:statuses].first)
  rescue ArgumentError => e
    Rails.logger.error "Error while processing whatsapp status update #{e.message}"
  end

  def update_message_with_status(message, status)
    message.status = status[:status]
    if status[:status] == 'failed' && status[:errors].present?
      error = status[:errors]&.first
      message.external_error = "#{error[:code]}: #{error[:title]}"
    end
    message.save!
  end

  def create_messages
    message = @processed_params[:messages].first
    log_error(message) && return if error_webhook_event?(message)

    process_in_reply_to(message)

    message_type == 'contacts' ? create_contact_messages(message) : create_regular_message(message)
  end

  # WhatsApp Coexistence Support:
  # When a user sends a message from the WhatsApp Business App (not Chatwoot),
  # WhatsApp still sends a webhook to keep the conversation in sync.
  # In this case, the 'from' field contains our own business phone number.
  # We detect this by comparing 'from' with our inbox's phone number.
  def outgoing_message?
    inbox_phone_number = @inbox.channel.phone_number.delete('+')
    payload_phone_number = @processed_params[:messages].first[:from]
    inbox_phone_number == payload_phone_number
  end

  def create_contact_messages(message)
    message['contacts'].each do |contact|
      create_message(contact)
      attach_contact(contact)
      @message.save!
    end
  end

  def create_regular_message(message)
    create_message(message)
    attach_files
    attach_location if message_type == 'location'
    @message.save!
  end

  def set_contact
    # WhatsApp Coexistence: For outgoing messages, the customer is in the 'to' field.
    # We use 'to' to find/create the contact instead of 'from' (which is our business number).
    if outgoing_message?
      recipient = @processed_params[:messages].first[:to]
      return if recipient.blank?

      waid = processed_waid(recipient)
      phone_number = "+#{recipient}"

      @contact_inbox = ::ContactInboxWithContactBuilder.new(
        source_id: waid,
        inbox: inbox,
        contact_attributes: { phone_number: phone_number }
      ).perform
      @contact = @contact_inbox.contact
      return
    end

    contact_params = @processed_params[:contacts]&.first
    return if contact_params.blank?

    waid = processed_waid(contact_params[:wa_id])

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: waid,
      inbox: inbox,
      contact_attributes: { name: contact_params.dig(:profile, :name), phone_number: "+#{@processed_params[:messages].first[:from]}" }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    # Update existing contact name if ProfileName is available and current name is just phone number
    update_contact_with_profile_name(contact_params)
  end

  def set_conversation
    # if lock to single conversation is disabled, we will create a new conversation if previous conversation is resolved
    @conversation = if @inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations
                                    .where.not(status: :resolved).last
                    end
    return if @conversation

    @conversation = ::Conversation.create!(conversation_params)
  end

  def attach_files
    return if %w[text button interactive location contacts].include?(message_type)

    attachment_payload = @processed_params[:messages].first[message_type.to_sym]
    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    # Transcode audio files (voice notes) from OGG/Opus to MP3 for Safari/iOS compatibility
    file_info = transcode_audio_if_needed(attachment_file)

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(message_type),
      file: {
        io: file_info[:file],
        filename: file_info[:filename],
        content_type: file_info[:content_type]
      }
    )
  end

  def attach_location
    location = @processed_params[:messages].first['location']
    location_name = location['name'] ? "#{location['name']}, #{location['address']}" : ''
    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(message_type),
      coordinates_lat: location['latitude'],
      coordinates_long: location['longitude'],
      fallback_title: location_name,
      external_url: location['url']
    )
  end

  def create_message(message)
    # WhatsApp Coexistence: Set message_type based on whether this is an echo of
    # our own outgoing message or an actual incoming message from a customer.
    # For outgoing messages, sender is nil (sent by business, not a contact).
    msg_type = outgoing_message? ? :outgoing : :incoming
    @message = @conversation.messages.build(
      content: message_content(message),
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      message_type: msg_type,
      sender: (msg_type == :incoming ? @contact : nil),
      source_id: message[:id].to_s,
      in_reply_to_external_id: @in_reply_to_external_id
    )
  end

  def attach_contact(contact)
    phones = contact[:phones]
    phones = [{ phone: 'Phone number is not available' }] if phones.blank?

    name_info = contact['name'] || {}
    contact_meta = {
      firstName: name_info['first_name'],
      lastName: name_info['last_name']
    }.compact

    phones.each do |phone|
      @message.attachments.new(
        account_id: @message.account_id,
        file_type: file_content_type(message_type),
        fallback_title: phone[:phone].to_s,
        meta: contact_meta
      )
    end
  end

  def update_contact_with_profile_name(contact_params)
    profile_name = contact_params.dig(:profile, :name)
    return if profile_name.blank?
    return if @contact.name == profile_name

    # Only update if current name exactly matches the phone number or formatted phone number
    return unless contact_name_matches_phone_number?

    @contact.update!(name: profile_name)
  end

  def contact_name_matches_phone_number?
    # WhatsApp Coexistence: Use 'to' for outgoing messages, 'from' for incoming.
    phone_number = outgoing_message? ? "+#{@processed_params[:messages].first[:to]}" : "+#{@processed_params[:messages].first[:from]}"
    formatted_phone_number = TelephoneNumber.parse(phone_number).international_number

    # Check if name matches phone number (raw or formatted)
    return true if @contact.name == phone_number || @contact.name == formatted_phone_number

    # WhatsApp Coexistence: Check if name looks like a Haikunator-generated name (e.g., "autumn-violet-854")
    # These are created when contact is created from an outgoing message echoes without profile info
    haikunator_pattern?(@contact.name)
  end

  def haikunator_pattern?(name)
    # Haikunator generates names like: "word-word-number" (e.g., "autumn-violet-854")
    # Pattern: lowercase-word, hyphen, lowercase-word, hyphen, 1-4 digit number
    name.present? && name.match?(/\A[a-z]+-[a-z]+-\d{1,4}\z/)
  end

  # Transcode OGG/Opus audio files to MP3 for Safari/iOS compatibility
  def transcode_audio_if_needed(attachment_file)
    return default_file_info(attachment_file) unless audio_message_type?

    service = AudioTranscodingService.new(attachment_file, content_type: attachment_file.content_type)
    service.perform
  end

  def audio_message_type?
    %w[audio voice].include?(message_type)
  end

  def default_file_info(attachment_file)
    {
      file: attachment_file,
      filename: attachment_file.original_filename,
      content_type: attachment_file.content_type
    }
  end
end
