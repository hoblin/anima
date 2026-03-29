# frozen_string_literal: true

module Tools
  # A deliberate reasoning space for the agent's inner voice. Creates a
  # pause between tool calls where the agent can organize thoughts, plan
  # next steps, or make decisions without interrupting the user.
  #
  # Think events bridge the gap between the analytical brain (subconscious
  # background processing) and speech (user-facing messages). Without this
  # tool, reasoning leaks into tool arguments as comments.
  #
  # Two visibility modes control how thoughts appear in the TUI:
  # - **inner** (default) — silent reasoning, visible only in verbose/debug
  # - **aloud** — narration shown in all view modes with a thought bubble
  #
  # The +maxLength+ on thoughts is controlled by +thinking_budget+ in settings.
  # Sub-agents receive half the main agent's budget — their tasks are scoped
  # and less complex, so runaway reasoning is a stronger signal of confusion.
  #
  # @example Silent planning between tool calls
  #   think(thoughts: "Three auth failures — likely a config issue, not individual tests.")
  #
  # @example Narrating approach for the user
  #   think(thoughts: "Checking the OAuth config first.", visibility: "aloud")
  class Think < Base
    def self.tool_name = "think"

    def self.description = "Think out loud or silently."

    # Schema is static — maxLength is injected at runtime by the registry
    # via {#dynamic_schema} when session context is available.
    def self.input_schema
      {
        type: "object",
        properties: {
          thoughts: {type: "string"},
          visibility: {
            type: "string",
            enum: ["inner", "aloud"],
            description: "inner (default) is silent. aloud is shown to the user."
          }
        },
        required: ["thoughts"]
      }
    end

    # @param session [Session, nil] current session for budget calculation
    def initialize(session: nil, **)
      @session = session
    end

    # Returns the tool schema with a thinking budget applied as maxLength
    # on the thoughts property. Sub-agents get half the budget.
    #
    # @return [Hash] Anthropic tool schema with maxLength constraint
    def dynamic_schema
      schema = self.class.schema.deep_dup
      budget = Anima::Settings.thinking_budget
      budget /= 2 if @session&.sub_agent?
      schema[:input_schema][:properties][:thoughts][:maxLength] = budget
      schema
    end

    # @param input [Hash] with "thoughts" and optional "visibility"
    # @return [String] acknowledgement — the value is in the call, not the result
    def execute(input)
      thoughts = input["thoughts"].to_s
      return {error: "Thoughts cannot be blank"} if thoughts.strip.empty?

      "OK"
    end
  end
end
