# frozen_string_literal: true

module Workflows
  # Loads workflow definitions from Markdown files and provides lookup.
  # Scans two directories:
  #   1. Built-in workflows shipped with Anima (workflows/ in the gem root)
  #   2. User-defined workflows (~/.anima/workflows/)
  # User workflows override built-in ones when names collide.
  class Registry
    # @return [Hash{String => Definition}] loaded definitions keyed by name
    attr_reader :workflows

    BUILTIN_DIR = File.expand_path("../../workflows", __dir__).freeze
    USER_DIR = File.expand_path("~/.anima/workflows").freeze

    def initialize
      @workflows = {}
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
      load_directory(USER_DIR)
      self
    end

    # Loads workflow definitions from a single directory (flat .md files only).
    #
    # @param dir [String] directory path to scan for workflow definitions
    # @return [void]
    def load_directory(dir)
      return unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.md")).sort.each do |path|
        definition = Definition.from_file(path)
        @workflows[definition.name] = definition
      rescue InvalidDefinitionError => error
        Rails.logger.warn("Skipping invalid workflow definition #{path}: #{error.message}")
      end
    end

    # Looks up a named workflow definition.
    #
    # @param name [String] workflow name
    # @return [Definition, nil]
    def find(name)
      @workflows[name]
    end

    # Workflow names and descriptions for inclusion in the analytical brain's context.
    #
    # @return [Hash{String => String}] name => description
    def catalog
      @workflows.transform_values(&:description)
    end

    # @return [Array<String>] registered workflow names
    def available_names
      @workflows.keys
    end

    # @return [Boolean]
    def any?
      @workflows.any?
    end

    # @return [Integer]
    def size
      @workflows.size
    end
  end
end
