# frozen_string_literal: true

module Skills
  # Loads skill definitions from Markdown files and provides lookup.
  # Supports two formats:
  #   - Flat file: skills/skill-name.md
  #   - Directory: skills/skill-name/SKILL.md (with optional references/ and examples/)
  # Scans two directories:
  #   1. Built-in skills shipped with Anima (skills/ in the gem root)
  #   2. User-defined skills (~/.anima/skills/)
  # User skills override built-in ones when names collide.
  class Registry
    # @return [Hash{String => Definition}] loaded definitions keyed by name
    attr_reader :skills

    BUILTIN_DIR = File.expand_path("../../skills", __dir__).freeze
    USER_DIR = File.expand_path("~/.anima/skills").freeze

    def initialize
      @skills = {}
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

    # Loads skill definitions from a single directory.
    # Supports flat files (*.md) and directory-based skills (*/SKILL.md).
    #
    # @param dir [String] directory path to scan for skill definitions
    #   (flat .md files and SKILL.md inside subdirectories)
    # @return [void]
    def load_directory(dir)
      return unless Dir.exist?(dir)

      skill_files(dir).each do |path|
        definition = Definition.from_file(path)
        @skills[definition.name] = definition
      rescue InvalidDefinitionError => error
        Rails.logger.warn("Skipping invalid skill definition #{path}: #{error.message}")
      end
    end

    # Looks up a named skill definition.
    #
    # @param name [String] skill name
    # @return [Definition, nil]
    def find(name)
      @skills[name]
    end

    # Skill names and descriptions for inclusion in the analytical brain's context.
    #
    # @return [Hash{String => String}] name => description
    def catalog
      @skills.transform_values(&:description)
    end

    # @return [Array<String>] registered skill names
    def available_names
      @skills.keys
    end

    # @return [Boolean]
    def any?
      @skills.any?
    end

    # @return [Integer]
    def size
      @skills.size
    end

    private

    # Finds all skill definition files in a directory — both flat .md files
    # and SKILL.md files inside subdirectories.
    #
    # @param dir [String] directory to scan
    # @return [Array<String>] sorted paths to skill definition files
    def skill_files(dir)
      Dir.glob([File.join(dir, "*.md"), File.join(dir, "*/SKILL.md")]).sort
    end
  end
end
