# frozen_string_literal: true

require "yaml"

module Agents
  class InvalidDefinitionError < StandardError; end

  # A named sub-agent parsed from a Markdown definition file.
  # YAML frontmatter holds metadata; the Markdown body is the system prompt.
  #
  # @example Definition file format
  #   ---
  #   name: codebase-analyzer
  #   description: Analyzes codebase implementation details.
  #   tools: read, bash
  #   model: claude-sonnet-4-5
  #   ---
  #
  #   You are a specialist at understanding HOW code works...
  class Definition
    # @return [String] unique agent identifier used in spawn_specialist(name: "...")
    attr_reader :name

    # @return [String] description shown to the LLM in the tool catalog
    attr_reader :description

    # @return [Array<String>] tool names available to this agent
    attr_reader :tools

    # @return [String] system prompt (Markdown body of the definition file)
    attr_reader :prompt

    # @return [String, nil] LLM model override (reserved for future use)
    attr_reader :model

    # @return [String, nil] TUI display color (reserved for future use)
    attr_reader :color

    # @return [Integer, nil] maximum conversation turns (reserved for future use)
    attr_reader :max_turns

    # @return [String] file path this definition was loaded from
    attr_reader :source_path

    def initialize(name:, description:, tools:, prompt:, model: nil, color: nil, max_turns: nil, source_path: "")
      @name = name
      @description = description
      @tools = tools
      @prompt = prompt
      @model = model
      @color = color
      @max_turns = max_turns
      @source_path = source_path
    end

    # Parses a Markdown file with YAML frontmatter into a Definition.
    #
    # @param path [String, Pathname] path to the .md file
    # @return [Definition]
    # @raise [InvalidDefinitionError] if required fields are missing or frontmatter is malformed
    def self.from_file(path)
      content = File.read(path)
      frontmatter, body = parse_frontmatter(content)

      validate_required_fields!(frontmatter, path)

      new(
        name: frontmatter["name"].to_s.strip,
        description: frontmatter["description"].to_s.strip,
        tools: parse_tools(frontmatter["tools"]),
        prompt: body.strip,
        model: frontmatter["model"]&.to_s&.strip,
        color: frontmatter["color"]&.to_s&.strip,
        max_turns: frontmatter["maxTurns"]&.to_i,
        source_path: path.to_s
      )
    end

    # @param content [String] raw file content with YAML frontmatter
    # @return [Array(Hash, String)] parsed frontmatter and body text
    # @raise [InvalidDefinitionError] if frontmatter is missing or malformed
    def self.parse_frontmatter(content)
      match = content.match(/\A---\s*\n(.*?\n)---\s*\n?(.*)\z/m)
      raise InvalidDefinitionError, "Missing YAML frontmatter" unless match

      frontmatter = YAML.safe_load(match[1])
      raise InvalidDefinitionError, "Frontmatter is not a valid YAML mapping" unless frontmatter.is_a?(Hash)

      [frontmatter, match[2]]
    end

    # Accepts comma-separated string or array of tool names.
    #
    # @param tools_value [String, Array, nil] raw tools field from frontmatter
    # @return [Array<String>] normalized lowercase tool names
    def self.parse_tools(tools_value)
      return [] if tools_value.nil?

      names = tools_value.is_a?(Array) ? tools_value : tools_value.to_s.split(",")
      names.map { |tool| tool.to_s.strip.downcase }.reject(&:empty?).uniq
    end

    def self.validate_required_fields!(frontmatter, path)
      %w[name description].each do |field|
        value = frontmatter[field].to_s.strip
        raise InvalidDefinitionError, "Missing required field '#{field}' in #{path}" if value.empty?
      end
    end

    private_class_method :parse_frontmatter, :parse_tools, :validate_required_fields!
  end
end
