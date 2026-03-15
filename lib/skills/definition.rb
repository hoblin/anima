# frozen_string_literal: true

require "yaml"

module Skills
  class InvalidDefinitionError < StandardError; end

  # A domain knowledge skill parsed from a Markdown definition file.
  # YAML frontmatter holds metadata; the Markdown body is the knowledge
  # content injected into the main agent's system prompt when active.
  #
  # Skills are passive knowledge — they describe WHAT you know, not
  # WHAT to do. The analytical brain activates/deactivates them based
  # on conversation context.
  #
  # @example Skill file format
  #   ---
  #   name: gh-issue
  #   description: "GitHub issue writing with WHAT/WHY/HOW framework."
  #   ---
  #
  #   # GitHub Issue Writing
  #   Write issues with clear rationale...
  class Definition
    # @return [String] unique skill identifier used in activate_skill(name: "...")
    attr_reader :name

    # @return [String] description shown to the analytical brain for relevance matching
    attr_reader :description

    # @return [String] knowledge content (Markdown body) injected into system prompt
    attr_reader :content

    # @return [String] file path this definition was loaded from
    attr_reader :source_path

    def initialize(name:, description:, content:, source_path: "")
      @name = name
      @description = description
      @content = content
      @source_path = source_path
    end

    # Parses a Markdown file with YAML frontmatter into a Definition.
    #
    # @param path [String, Pathname] path to the .md file
    # @return [Definition]
    # @raise [InvalidDefinitionError] if required fields are missing or frontmatter is malformed
    def self.from_file(path)
      raw = File.read(path)
      frontmatter, body = parse_frontmatter(raw)

      validate_required_fields!(frontmatter, path)

      new(
        name: frontmatter["name"].to_s.strip,
        description: frontmatter["description"].to_s.strip,
        content: body.strip,
        source_path: path.to_s
      )
    end

    # @param raw [String] raw file content with YAML frontmatter
    # @return [Array(Hash, String)] parsed frontmatter and body text
    # @raise [InvalidDefinitionError] if frontmatter is missing or malformed
    def self.parse_frontmatter(raw)
      # Opening "---" must be followed by a newline (not just whitespace).
      # Non-greedy (.*?\n) captures YAML lines up to the closing "---".
      # Closing "---" may optionally be followed by a newline before the body.
      # The /m flag lets (.*) in the body capture across newlines.
      match = raw.match(/\A---\s*\n(.*?\n)---\s*\n?(.*)\z/m)
      raise InvalidDefinitionError, "Missing YAML frontmatter" unless match

      frontmatter = YAML.safe_load(match[1])
      raise InvalidDefinitionError, "Frontmatter is not a valid YAML mapping" unless frontmatter.is_a?(Hash)

      [frontmatter, match[2]]
    end

    NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/

    def self.validate_required_fields!(frontmatter, path)
      %w[name description].each do |field|
        value = frontmatter[field].to_s.strip
        raise InvalidDefinitionError, "Missing required field '#{field}' in #{path}" if value.empty?
      end

      name = frontmatter["name"].to_s.strip
      unless name.match?(NAME_FORMAT)
        raise InvalidDefinitionError,
          "Invalid skill name '#{name}' in #{path} — must be lowercase alphanumeric with hyphens/underscores"
      end
    end

    private_class_method :parse_frontmatter, :validate_required_fields!
  end
end
