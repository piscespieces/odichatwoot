require 'agents'

class Captain::Assistant::AgentRunnerService
  include Integrations::LlmInstrumentation

  CONVERSATION_STATE_ATTRIBUTES = %i[
    id display_id inbox_id contact_id status priority
    label_list custom_attributes additional_attributes
  ].freeze

  CONTACT_STATE_ATTRIBUTES = %i[
    id name email phone_number identifier contact_type
    custom_attributes additional_attributes
  ].freeze

  def initialize(assistant:, conversation: nil, callbacks: {})
    @assistant = assistant
    @conversation = conversation
    @callbacks = callbacks
  end

  def generate_response(message_history: [])
    @message_history = message_history
    agents = build_and_wire_agents
    context = build_context(message_history)
    message_to_process = extract_last_user_message(message_history)
    runner = Agents::Runner.with_agents(*agents)
    runner = add_instrumentation_callbacks(runner)
    runner = add_callbacks_to_runner(runner) if @callbacks.any?

    result = instrument_agent_session(agent_instrumentation_params) do
      runner.run(message_to_process, context: context, max_turns: 100)
    end

    process_agent_result(result)
  rescue StandardError => e
    # when running the agent runner service in a rake task, the conversation might not have an account associated
    # for regular production usage, it will run just fine
    ChatwootExceptionTracker.new(e, account: @conversation&.account).capture_exception
    Rails.logger.error "[Captain V2] AgentRunnerService error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    error_response(e.message)
  end

  private

  def build_context(message_history)
    conversation_history = message_history.map do |msg|
      content = extract_text_from_content(msg[:content])

      {
        role: msg[:role].to_sym,
        content: content,
        agent_name: msg[:agent_name]
      }
    end

    {
      conversation_history: conversation_history,
      state: build_state
    }
  end

  def extract_last_user_message(message_history)
    last_user_msg = message_history.reverse.find { |msg| msg[:role] == 'user' }

    extract_text_from_content(last_user_msg[:content])
  end

  def extract_text_from_content(content)
    # Handle structured output from agents
    return content[:response] || content['response'] || content.to_s if content.is_a?(Hash)

    return content unless content.is_a?(Array)

    text_parts = content.select { |part| part[:type] == 'text' }.pluck(:text)
    text_parts.join(' ')
  end

  # Response formatting methods
  def process_agent_result(result)
    Rails.logger.info "[Captain V2] Agent result: #{result.inspect}"
    response = format_response(result.output)

    # Extract agent name from context
    response['agent_name'] = result.context&.dig(:current_agent)

    response
  end

  def format_response(output)
    return output.with_indifferent_access if output.is_a?(Hash)

    # Fallback for backwards compatibility
    {
      'response' => output.to_s,
      'reasoning' => 'Processed by agent'
    }
  end

  def error_response(error_message)
    {
      'response' => 'conversation_handoff',
      'reasoning' => "Error occurred: #{error_message}"
    }
  end

  def build_state
    state = {
      account_id: @assistant.account_id,
      assistant_id: @assistant.id,
      assistant_config: @assistant.config
    }

    if @conversation
      state[:conversation] = @conversation.attributes.symbolize_keys.slice(*CONVERSATION_STATE_ATTRIBUTES)
      state[:contact] = @conversation.contact.attributes.symbolize_keys.slice(*CONTACT_STATE_ATTRIBUTES) if @conversation.contact
    end

    state
  end

  def build_and_wire_agents
    assistant_agent = @assistant.agent
    scenario_agents = @assistant.scenarios.enabled.map(&:agent)

    assistant_agent.register_handoffs(*scenario_agents) if scenario_agents.any?

    # Mesh topology: each scenario can handoff to the main assistant AND all other scenarios
    scenario_agents.each do |scenario_agent|
      handoff_targets = [assistant_agent] + (scenario_agents - [scenario_agent])
      scenario_agent.register_handoffs(*handoff_targets)
    end

    [assistant_agent] + scenario_agents
  end

  def add_callbacks_to_runner(runner)
    runner = add_agent_thinking_callback(runner) if @callbacks[:on_agent_thinking]
    runner = add_tool_start_callback(runner) if @callbacks[:on_tool_start]
    runner = add_tool_complete_callback(runner) if @callbacks[:on_tool_complete]
    runner = add_agent_handoff_callback(runner) if @callbacks[:on_agent_handoff]
    runner
  end

  def add_instrumentation_callbacks(runner)
    return runner unless ChatwootApp.otel_enabled?

    runner.on_tool_start do |tool_call|
      start_tool_span(tool_call)
    rescue StandardError => e
      Rails.logger.warn "[Captain V2] Instrumentation tool_start error: #{e.message}"
    end

    runner.on_tool_complete do |result|
      end_tool_span(result)
    rescue StandardError => e
      Rails.logger.warn "[Captain V2] Instrumentation tool_complete error: #{e.message}"
    end

    runner
  end

  def agent_instrumentation_params
    {
      span_name: 'llm.captain.assistant_v2',
      account_id: @assistant.account_id,
      conversation_id: @conversation&.display_id,
      feature_name: 'assistant_v2',
      model: agent_model,
      messages: @message_history || [],
      temperature: @assistant.temperature || 0.7,
      metadata: {
        assistant_id: @assistant.id,
        conversation_id: @conversation&.id
      }
    }
  end

  def agent_model
    InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || LlmConstants::DEFAULT_MODEL
  end

  def add_agent_thinking_callback(runner)
    runner.on_agent_thinking do |*args|
      @callbacks[:on_agent_thinking].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for agent_thinking: #{e.message}"
    end
  end

  def add_tool_start_callback(runner)
    runner.on_tool_start do |*args|
      @callbacks[:on_tool_start].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for tool_start: #{e.message}"
    end
  end

  def add_tool_complete_callback(runner)
    runner.on_tool_complete do |*args|
      @callbacks[:on_tool_complete].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for tool_complete: #{e.message}"
    end
  end

  def add_agent_handoff_callback(runner)
    runner.on_agent_handoff do |*args|
      @callbacks[:on_agent_handoff].call(*args)
    rescue StandardError => e
      Rails.logger.warn "[Captain] Callback error for agent_handoff: #{e.message}"
    end
  end
end
