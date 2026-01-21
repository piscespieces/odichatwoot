# frozen_string_literal: true

# WhatsApp Coexistence Support Module
#
# This module handles the `smb_message_echoes` webhook from WhatsApp Business API.
# When a user sends a message from the WhatsApp Business App (not Chatwoot),
# WhatsApp sends an "echo" webhook to keep the conversation in sync.
#
# These webhooks use the key `message_echoes` instead of `messages`.
# The `from` field contains the business phone number, and `to` contains the customer.
#
# Reference: https://developers.facebook.com/docs/whatsapp/cloud-api/webhooks/components#smb_message_echoes
module Whatsapp::IncomingMessageCoexistenceHelpers
  extend ActiveSupport::Concern

  private

  # Process messages sent from WhatsApp Business App.
  # These webhooks have the payload key 'message_echoes' instead of 'messages'.
  def process_message_echoes
    echo = @processed_params[:message_echoes].first
    return if echo.blank?
    return if unprocessable_message_type?(echo[:type])
    return if find_message_by_source_id(echo[:id]) || message_echo_under_process?(echo[:id])

    cache_message_echo_in_redis(echo[:id])
    find_or_create_contact_for_echo(echo)
    return unless @contact

    ActiveRecord::Base.transaction do
      set_conversation
      create_echo_message(echo)
      clear_message_echo_from_redis(echo[:id])
    end
  end

  # Find/create the contact using the 'to' field from the echo (the customer).
  def find_or_create_contact_for_echo(echo)
    recipient = echo[:to]
    return if recipient.blank?

    waid = processed_waid(recipient)
    phone_number = "+#{recipient}"

    @contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: waid,
      inbox: inbox,
      contact_attributes: { phone_number: phone_number }
    ).perform
    @contact = @contact_inbox.contact
  end

  # Create an outgoing message from the echo payload.
  def create_echo_message(echo)
    @message = @conversation.messages.build(
      content: echo_message_content(echo),
      account_id: @inbox.account_id,
      inbox_id: @inbox.id,
      message_type: :outgoing,
      sender: nil, # Sent by business, not a contact
      source_id: echo[:id].to_s
    )
    attach_echo_files(echo) if echo[:type] != 'text'
    @message.save!
  end

  # Extract message content from echo payload.
  def echo_message_content(echo)
    echo.dig(:text, :body) ||
      echo.dig(:button, :text) ||
      echo.dig(:interactive, :button_reply, :title) ||
      echo.dig(:interactive, :list_reply, :title) ||
      echo.dig(echo[:type].to_sym, :caption)
  end

  # Attach files from echo payload (images, videos, documents, etc.)
  def attach_echo_files(echo)
    type = echo[:type]
    return if %w[text button interactive location contacts].include?(type)

    attachment_payload = echo[type.to_sym]
    return if attachment_payload.blank?

    @message.content ||= attachment_payload[:caption]

    attachment_file = download_attachment_file(attachment_payload)
    return if attachment_file.blank?

    @message.attachments.new(
      account_id: @message.account_id,
      file_type: file_content_type(type),
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename,
        content_type: attachment_file.content_type
      }
    )
  end

  # Redis helpers for message echo deduplication
  def message_echo_under_process?(id)
    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: id)
    Redis::Alfred.get(key)
  end

  def cache_message_echo_in_redis(id)
    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: id)
    ::Redis::Alfred.setex(key, true)
  end

  def clear_message_echo_from_redis(id)
    key = format(Redis::RedisKeys::MESSAGE_SOURCE_KEY, id: id)
    ::Redis::Alfred.delete(key)
  end
end
