# frozen_string_literal: true

require "toml-rb"
require "pathname"

module Anima
  # Merges new default settings into an existing config.toml without
  # overwriting user-customized values.
  #
  # Preserves the user's formatting and comments by extracting text blocks
  # from the template and appending them to the config file. Missing entire
  # sections are appended with their separator comments; missing keys within
  # existing sections are inserted at the end of the section.
  #
  # @example
  #   result = ConfigMigrator.new.run
  #   result.status    #=> :updated
  #   result.additions #=> [#<Addition section="paths" key="soul" value="/home/...">]
  class ConfigMigrator
    ANIMA_HOME = File.expand_path("~/.anima")
    TEMPLATE_PATH = File.expand_path("../../templates/config.toml", __dir__).freeze

    # A single config key that was added during migration.
    # @!attribute [r] section [String] TOML section name
    # @!attribute [r] key [String] key name within the section
    # @!attribute [r] value [Object] default value from the template
    Addition = Data.define(:section, :key, :value)

    # Outcome of a migration run.
    # @!attribute [r] status [Symbol] :not_found, :up_to_date, or :updated
    # @!attribute [r] additions [Array<Addition>] keys that were added
    Result = Data.define(:status, :additions)

    # Section separator pattern used in the template (e.g. "# ─── LLM ───...").
    SEPARATOR_PATTERN = /^# ─── /

    # @param config_path [String] path to the user's config.toml
    # @param template_path [String] path to the default config template
    # @param anima_home [String] expanded path to ~/.anima (for template interpolation)
    def initialize(config_path: File.join(ANIMA_HOME, "config.toml"),
      template_path: TEMPLATE_PATH,
      anima_home: ANIMA_HOME)
      @config_path = Pathname.new(config_path)
      @template_path = Pathname.new(template_path)
      @anima_home = anima_home
    end

    # Merge missing settings from the template into the user's config.
    #
    # @return [Result] status (:not_found, :up_to_date, :updated) and additions list
    def run
      return Result.new(status: :not_found, additions: []) unless @config_path.exist?

      template_text = resolve_template
      template_config = TomlRB.parse(template_text)
      user_config = TomlRB.load_file(@config_path.to_s)

      additions = find_additions(user_config, template_config)
      return Result.new(status: :up_to_date, additions: []) if additions.empty?

      apply_additions(additions, template_text)
      Result.new(status: :updated, additions: additions)
    end

    private

    # Replace template placeholders with actual paths.
    def resolve_template
      File.read(@template_path.to_s).gsub("{{ANIMA_HOME}}") { @anima_home }
    end

    # Compare user config against template defaults.
    # Returns additions for keys present in template but absent from user config.
    def find_additions(user, template)
      template.flat_map do |section, keys|
        missing_keys_in_section(user, section, keys)
      end
    end

    def missing_keys_in_section(user, section, keys)
      keys.filter_map do |key, value|
        next if user.key?(section) && user[section].key?(key)

        Addition.new(section: section, key: key, value: value)
      end
    end

    # Write missing settings into the user's config file, preserving existing content.
    def apply_additions(additions, template_text)
      user_text = @config_path.read
      template_blocks = parse_section_blocks(template_text)

      missing_sections, missing_keys = additions.partition do |addition|
        !user_text.match?(/^\[#{Regexp.escape(addition.section)}\]/)
      end

      user_text = append_missing_sections(user_text, missing_sections, template_blocks)
      user_text = insert_missing_keys(user_text, missing_keys, template_text)

      @config_path.write(user_text)
    end

    def append_missing_sections(user_text, missing_sections, template_blocks)
      missing_sections.map(&:section).uniq.each do |section|
        block = template_blocks[section]
        next unless block

        user_text = "#{user_text.rstrip}\n\n#{block.rstrip}\n"
      end
      user_text
    end

    def insert_missing_keys(user_text, missing_keys, template_text)
      missing_keys.each do |addition|
        section = addition.section
        key_block = extract_key_block(template_text, section, addition.key)
        next unless key_block

        user_text = insert_key_in_section(user_text, section, key_block)
      end
      user_text
    end

    # Split template into section blocks keyed by TOML section name.
    # Each block spans from its separator comment to the next separator (exclusive).
    def parse_section_blocks(template_text)
      lines = template_text.lines
      separator_indices = lines.each_index.select { |idx| lines[idx].match?(SEPARATOR_PATTERN) }
      block_ranges = build_block_ranges(separator_indices, lines.length)

      block_ranges.each_with_object({}) do |(start_idx, end_idx), blocks|
        block_lines = lines[start_idx..end_idx]
        section_name = extract_section_name(block_lines)
        blocks[section_name] = block_lines.join if section_name
      end
    end

    # Find the TOML section name (e.g. "llm") within a block of lines.
    def extract_section_name(block_lines)
      header = block_lines.find { |line| line.match?(/^\[\w+\]/) }
      header&.match(/^\[(\w+)\]/)&.[](1)
    end

    # Build [start, end] pairs from separator indices.
    def build_block_ranges(separator_indices, total_lines)
      separator_indices.each_with_index.map do |start_idx, position|
        next_pos = position + 1
        end_idx = (next_pos < separator_indices.length) ? separator_indices[next_pos] - 1 : total_lines - 1
        [start_idx, end_idx]
      end
    end

    # Extract a single key and its preceding comment lines from the template.
    def extract_key_block(template_text, section, key)
      lines = template_text.lines
      in_section = false

      lines.each_with_index do |line, line_idx|
        if line.match?(/^\[#{Regexp.escape(section)}\]/)
          in_section = true
        elsif line.match?(/^\[/) && in_section
          break
        elsif in_section && line.match?(/^#{Regexp.escape(key)}\s*=/)
          return build_key_block(lines, line_idx)
        end
      end
      nil
    end

    # Walk backward from a key line to collect preceding comment lines.
    def build_key_block(lines, key_idx)
      comment_start = key_idx
      scan_idx = key_idx - 1
      while scan_idx >= 0 && lines[scan_idx].match?(/^#/)
        comment_start = scan_idx
        scan_idx -= 1
      end
      "\n#{lines[comment_start..key_idx].join}"
    end

    # Insert a key block at the end of an existing section
    # (before the next separator comment or EOF).
    def insert_key_in_section(user_text, section, key_block)
      lines = user_text.lines
      insert_at = find_section_end(lines, section)
      insert_at -= 1 while insert_at > 0 && lines[insert_at - 1].strip.empty?

      lines.insert(insert_at, key_block)
      lines.join
    end

    # Find the line index where a section ends (next separator or section header).
    def find_section_end(lines, section)
      in_section = false
      lines.each_with_index do |line, line_idx|
        if line.match?(/^\[#{Regexp.escape(section)}\]/)
          in_section = true
        elsif in_section && (line.match?(SEPARATOR_PATTERN) || line.match?(/^\[/))
          return line_idx
        end
      end
      lines.length
    end
  end
end
