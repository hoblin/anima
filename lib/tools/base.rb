# frozen_string_literal: true

module Tools
  # Abstract base class for all Anima tools. Subclasses must implement
  # the class-level schema methods and the instance-level {#execute} method.
  #
  # @abstract Subclass and implement {.tool_name}, {.description},
  #   {.input_schema}, and {#execute}
  #
  # @example Implementing a tool
  #   class Tools::Echo < Tools::Base
  #     def self.tool_name = "echo"
  #     def self.description = "Echoes input back"
  #     def self.input_schema
  #       {type: "object", properties: {text: {type: "string"}}, required: ["text"]}
  #     end
  #
  #     def execute(input)
  #       input["text"]
  #     end
  #   end
  class Base
    class << self
      # @return [String] unique tool identifier sent to the LLM
      def tool_name
        raise NotImplementedError, "#{self} must implement .tool_name"
      end

      # @return [String] human-readable description for the LLM
      def description
        raise NotImplementedError, "#{self} must implement .description"
      end

      # @return [Hash] JSON Schema describing the tool's input parameters
      def input_schema
        raise NotImplementedError, "#{self} must implement .input_schema"
      end

      # Builds the schema hash expected by the Anthropic tools API.
      # @return [Hash] with :name, :description, and :input_schema keys
      def schema
        {name: tool_name, description: description, input_schema: input_schema}
      end
    end

    # Accepts and discards context keywords so that the Registry can pass
    # shared dependencies (e.g. shell_session) to any tool uniformly.
    # Subclasses that need specific context should override with named kwargs.
    def initialize(**) = nil

    # Execute the tool with the given input.
    # @param input [Hash] parsed input matching {.input_schema}
    # @return [String, Hash] result content; Hash with :error key signals failure
    def execute(input)
      raise NotImplementedError, "#{self.class} must implement #execute"
    end
  end
end
