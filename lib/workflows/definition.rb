# frozen_string_literal: true

require "yaml"

module Workflows
  class InvalidDefinitionError < StandardError; end

  # A workflow parsed from a Markdown definition file.
  # YAML frontmatter holds metadata; the Markdown body contains free-form
  # instructions that the analytical brain reads and converts into goals.
  #
  # Workflows are operational recipes — they describe WHAT to do step by
  # step. The analytical brain uses judgment to decompose workflow prose
  # into tracked goals based on the user's specific context.
  #
  # @example Workflow file format
  #   ---
  #   name: feature
  #   description: "Implement a GitHub issue end-to-end."
  #   ---
  #
  #   ## Context
  #   Create and complete a new feature...
  class Definition
    # @return [String] unique workflow identifier used in read_workflow(name: "...")
    attr_reader :name

    # @return [String] description shown to the analytical brain for relevance matching
    attr_reader :description

    # @return [String] workflow content (Markdown body) — free-form instructions
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
          "Invalid workflow name '#{name}' in #{path} — must be lowercase alphanumeric with hyphens/underscores"
      end
    end

    private_class_method :parse_frontmatter, :validate_required_fields!
  end
end
