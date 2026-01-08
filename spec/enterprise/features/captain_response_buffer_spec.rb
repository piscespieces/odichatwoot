require 'rails_helper'

RSpec.describe 'Captain Response Buffer', type: :request do
  let(:account) { create(:account) }
  let(:assistant) { create(:captain_assistant, account: account) }
  let(:contact) { create(:contact, account: account) }

  context 'with WhatsApp inbox' do
    let(:whatsapp_channel) { create(:channel_whatsapp, account: account) }
    let(:inbox) { create(:inbox, account: account, channel: whatsapp_channel) }
    let(:conversation) { create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending) }

    before do
      allow_any_instance_of(Captain::Conversation::ResponseBuilderJob).to receive(:captain_v2_enabled?).and_return(false)
      allow_any_instance_of(Whatsapp::Providers::Whatsapp360DialogService).to receive(:validate_provider_config?).and_return(true)
      allow_any_instance_of(Whatsapp::Providers::Whatsapp360DialogService).to receive(:sync_templates).and_return(true)
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    end

    describe 'HookExecutionService delay' do
      it 'schedules ResponseBuilderJob with a 3-second delay' do
        expect(Captain::Conversation::ResponseBuilderJob).to receive(:set).with(wait: 3.seconds).and_call_original
        expect_any_instance_of(ActiveJob::ConfiguredJob).to receive(:perform_later).with(conversation, assistant)

        create(:message, conversation: conversation, message_type: :incoming)
      end
    end

    describe 'ResponseBuilderJob debounce' do
      let(:mock_llm_service) { instance_double(Captain::Llm::AssistantChatService) }

      before do
        allow(Captain::Llm::AssistantChatService).to receive(:new).and_return(mock_llm_service)
        allow(mock_llm_service).to receive(:generate_response).and_return({ 'response' => 'Debounced response' })

        mock_v2_service = instance_double(Captain::Assistant::AgentRunnerService)
        allow(Captain::Assistant::AgentRunnerService).to receive(:new).and_return(mock_v2_service)
        allow(mock_v2_service).to receive(:generate_response).and_return({ 'response' => 'Debounced response V2' })
      end

      it 'skips execution if a newer message has arrived' do
        # First message arrives
        create(:message, conversation: conversation, message_type: :incoming, created_at: 2.seconds.ago)

        # Second message arrives after 1 second
        create(:message, conversation: conversation, message_type: :incoming, created_at: 1.second.ago)

        # Job runs. It should find the newer message (1s ago) which is > BUFFER_TIME.ago (3s ago)
        # Wait, BUFFER_TIME.ago is 3 seconds ago. 1s ago IS newer than 3s ago.
        # last_incoming.created_at > BUFFER_TIME.ago
        # (Current - 1s) > (Current - 3s) => true.
        expect(mock_llm_service).not_to receive(:generate_response)

        Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant)
      end

      it 'executes if no newer message exists' do
        create(:message, conversation: conversation, message_type: :incoming, created_at: 4.seconds.ago)

        expect(mock_llm_service).to receive(:generate_response)

        Captain::Conversation::ResponseBuilderJob.perform_now(conversation, assistant)
      end
    end
  end

  context 'with Instagram inbox' do
    let(:instagram_channel) { create(:channel_instagram, account: account) }
    let(:inbox) { create(:inbox, account: account, channel: instagram_channel) }
    let(:conversation) { create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    end

    it 'schedules ResponseBuilderJob with a 3-second delay' do
      expect(Captain::Conversation::ResponseBuilderJob).to receive(:set).with(wait: 3.seconds).and_call_original
      expect_any_instance_of(ActiveJob::ConfiguredJob).to receive(:perform_later).with(conversation, assistant)

      create(:message, conversation: conversation, message_type: :incoming)
    end
  end

  context 'with Web Widget inbox (no buffer)' do
    let(:web_widget) { create(:channel_widget, account: account) }
    let(:inbox) { create(:inbox, account: account, channel: web_widget) }
    let(:conversation) { create(:conversation, inbox: inbox, account: account, contact: contact, status: :pending) }

    before do
      create(:captain_inbox, captain_assistant: assistant, inbox: inbox)
    end

    it 'schedules ResponseBuilderJob immediately' do
      expect(Captain::Conversation::ResponseBuilderJob).not_to receive(:set)
      expect(Captain::Conversation::ResponseBuilderJob).to receive(:perform_later).with(conversation, assistant)

      create(:message, conversation: conversation, message_type: :incoming)
    end
  end
end
