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
  # @example Silent planning between tool calls
  #   think(thoughts: "Three auth failures — likely a config issue, not individual tests.")
  #
  # @example Narrating approach for the user
  #   think(thoughts: "Checking the OAuth config first.", visibility: "aloud")
  class Think < Base
    def self.tool_name = "think"

    def self.description
      "Express your internal reasoning between tool calls. " \
        "Use this to analyze intermediate results, plan next steps, or make decisions before continuing. " \
        "Set visibility to \"aloud\" when you want the user to see your thought process."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          thoughts: {
            type: "string",
            description: "Your reasoning, analysis, or internal monologue"
          },
          visibility: {
            type: "string",
            enum: ["inner", "aloud"],
            description: "\"inner\" (default) for silent reasoning; \"aloud\" to narrate for the user"
          }
        },
        required: ["thoughts"]
      }
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
