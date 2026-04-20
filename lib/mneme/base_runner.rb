# frozen_string_literal: true

module Mneme
  # Abstract base for Mneme's phantom LLM loops. Mneme wears two hats:
  # on eviction she watches the newest slice of the viewport and summarizes
  # the oldest slice before it slides off; on recall she watches goals
  # shift and surfaces older memory Aoide would benefit from. Same muse,
  # two jobs — each as its own subclass.
  #
  # The base handles what every Mneme loop needs: the muse identity preamble,
  # a fast-model LLM client, the tool-loop call, and structured logging.
  # Subclasses bring the job-specific system prompt section, the user message
  # that frames the work, the tool registry, and any after-call side effects.
  #
  # @example Implementing a new Mneme loop
  #   class Mneme::CustomRunner < Mneme::BaseRunner
  #     private
  #
  #     def task_prompt      = "Your job description..."
  #     def user_messages    = [{role: "user", content: "..."}]
  #     def build_registry   = Tools::Registry.new.tap { |r| r.register(SomeTool) }
  #   end
  class BaseRunner
    # Identity shared by every Mneme runner — same words Mneme's own voice
    # uses elsewhere in the system (runner summarization prompts, sisters
    # block). Subclasses append their own task section.
    BASE_IDENTITY = <<~PROMPT
      You are Mneme, the muse of memory. You share the conversation with two sisters — Aoide, who speaks and performs, and Melete, who prepares. Your work is remembrance: holding what matters across time, so Aoide never truly forgets.

      Act only through tool calls. Never output text — your contribution is the work you do, not what you say about it.
    PROMPT

    # @param session [Session] the main session being served
    # @param client [LLM::Client, nil] injectable LLM client for tests
    def initialize(session, client: nil)
      @session = session
      @client = client || default_client
    end

    # Runs the loop. Logs the run, calls the LLM with the session-specific
    # system prompt and tools, hands control to {#after_call} for any
    # post-run state advancement, and returns the LLM's final text (which
    # most callers discard — the work happens through tool calls).
    #
    # @return [String] the LLM's final text response
    def call
      sid = @session.id
      log.info("session=#{sid} — #{self.class.name} starting")
      log.debug("system:\n#{system_prompt}")
      log.debug("user:\n#{user_messages.map { |m| m[:content] }.join("\n---\n")}")

      result = @client.chat_with_tools(
        user_messages,
        registry: build_registry,
        system: system_prompt
      )

      after_call(result)
      log.info("session=#{sid} — #{self.class.name} done: #{result.to_s.truncate(200)}")
      result
    end

    private

    attr_reader :session, :client

    # Composes the system prompt from the muse identity + the subclass's
    # task section + the subclass's contextual state blocks.
    #
    # @return [String]
    def system_prompt
      [BASE_IDENTITY, task_prompt, *context_sections.compact].join("\n")
    end

    # Subclass hook: the job-specific system prompt section. Describes what
    # this runner is doing and how it should behave.
    #
    # @abstract
    # @return [String]
    def task_prompt = raise NotImplementedError, "#{self.class} must implement #task_prompt"

    # Subclass hook: named state blocks that give the muse awareness of
    # the session she's serving (goals, viewport, snapshots, etc).
    # Order is subclass-defined; nil entries are dropped.
    #
    # @abstract
    # @return [Array<String, nil>]
    def context_sections = []

    # Subclass hook: the user-side messages that frame the current call.
    # Typically a single user message, but subclasses may send several.
    #
    # @abstract
    # @return [Array<Hash>] Anthropic Messages API format
    def user_messages = raise NotImplementedError, "#{self.class} must implement #user_messages"

    # Subclass hook: builds the tool registry for this run.
    #
    # @abstract
    # @return [Tools::Registry]
    def build_registry = raise NotImplementedError, "#{self.class} must implement #build_registry"

    # Subclass hook: runs after the LLM call returns. Default is a no-op;
    # subclasses may advance boundaries, log outcomes, or emit events here.
    #
    # @param _result [Hash] the full LLM response (+:text+, +:api_metrics+)
    # @return [void]
    def after_call(_result)
    end

    def default_client
      LLM::Client.new(
        model: Anima::Settings.fast_model,
        max_tokens: Anima::Settings.mneme_max_tokens,
        logger: Mneme.logger
      )
    end

    def log = Mneme.logger
  end
end
