# frozen_string_literal: true

module Agents
  # Loads named agent definitions from Markdown files and provides lookup.
  # Scans two directories:
  #   1. Built-in agents shipped with Anima (agents/ in the gem root)
  #   2. User-defined agents (~/.anima/agents/)
  # User agents override built-in ones when names collide.
  class Registry
    # @return [Hash{String => Definition}] loaded definitions keyed by name
    attr_reader :agents

    BUILTIN_DIR = File.expand_path("../../agents", __dir__).freeze
    USER_DIR = File.expand_path("~/.anima/agents").freeze

    def initialize
      @agents = {}
    end

    # Returns the global registry, lazily loaded on first access.
    #
    # @return [Registry]
    def self.instance
      @instance ||= new.load_all
    end

    # Reloads the global registry from disk.
    #
    # @return [Registry]
    def self.reload!
      @instance = new.load_all
    end

    # Loads definitions from both built-in and user directories.
    # User definitions override built-in ones with the same name.
    #
    # @return [self]
    def load_all
      load_directory(BUILTIN_DIR)
      load_directory(USER_DIR) unless Rails.env.test?
      self
    end

    # Loads agent definitions from a single directory.
    #
    # @param dir [String] directory path to scan for .md files
    # @return [void]
    def load_directory(dir)
      return unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.md")).sort.each do |path|
        definition = Definition.from_file(path)
        validate_tools!(definition.name, definition.tools)
        @agents[definition.name] = definition
      rescue InvalidDefinitionError => error
        warn "Skipping invalid agent definition #{path}: #{error.message}"
      end
    end

    # Looks up a named agent definition.
    #
    # @param name [String] agent name
    # @return [Definition, nil]
    def get(name)
      @agents[name]
    end

    # Agent names and descriptions for inclusion in tool documentation.
    #
    # @return [Hash{String => String}] name => description
    def catalog
      @agents.transform_values(&:description)
    end

    # @return [Array<String>] registered agent names
    def names
      @agents.keys
    end

    # @return [Boolean]
    def any?
      @agents.any?
    end

    # @return [Integer]
    def size
      @agents.size
    end

    private

    # Validates that all declared tool names are recognized standard tools.
    #
    # @param agent_name [String] agent name for error messages
    # @param tools [Array<String>] declared tool names
    # @raise [InvalidDefinitionError] if any tool name is unknown
    def validate_tools!(agent_name, tools)
      return if tools.empty?

      unknown = tools - Tools::Registry::STANDARD_TOOLS_BY_NAME.keys
      return if unknown.empty?

      raise InvalidDefinitionError, "Unknown tools in '#{agent_name}': #{unknown.join(", ")}"
    end
  end
end
