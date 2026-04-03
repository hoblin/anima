# frozen_string_literal: true

require "toml-rb"

module TUI
  # TUI-specific configuration backed by +~/.anima/tui.toml+.
  #
  # Zero Rails dependency — the TUI is a standalone client process.
  #
  # Accessors are generated automatically from the template TOML file.
  # Convention: method name = +section_key+ (e.g. +[hud] min_width+ →
  # +hud_min_width+). To add a setting, add the key to +tui.toml+ — the
  # accessor appears automatically.
  #
  # Settings are loaded once at startup. Restart the TUI to pick up
  # changes — it's a thin client, the brain won't notice.
  #
  # @example Reading a setting
  #   TUI::Settings.connection_default_host  #=> "localhost:42134"
  #   TUI::Settings.hud_min_width            #=> 24
  #
  # @see Anima::Installer#create_tui_config creates the config file
  module Settings
    DEFAULT_PATH = File.expand_path("~/.anima/tui.toml")
    TEMPLATE_PATH = File.expand_path("../../../templates/tui.toml", __FILE__)
    TEMPLATE = TomlRB.load_file(TEMPLATE_PATH)

    class MissingConfigError < StandardError; end
    class MissingSettingError < StandardError; end

    @config_path = nil

    class << self
      TEMPLATE.each do |section, keys|
        keys.each_key { |key| attr_reader :"#{section}_#{key}" }
      end

      # Override config file path (for testing).
      # Triggers a load so the new config takes effect immediately.
      #
      # @param path [String, nil] custom path, or +nil+ to restore default
      def config_path=(path)
        @config_path = path
        load! if path
      end

      # @return [String] active config file path
      def config_path
        @config_path || DEFAULT_PATH
      end

      # Clears all loaded settings and resets to default path.
      # Useful in test teardown.
      def reset!
        @config_path = nil
        TEMPLATE.each do |section, keys|
          keys.each_key { |key| instance_variable_set(:"@#{section}_#{key}", nil) }
        end
      end

      # Parses the config file and populates all setting ivars.
      #
      # @raise [MissingConfigError] when tui.toml does not exist
      # @raise [MissingSettingError] when a template key is missing from config
      def load!
        path = config_path
        unless File.exist?(path)
          raise MissingConfigError,
            "TUI config file not found: #{path}. Run `anima install` to create it."
        end

        parsed = TomlRB.load_file(path)
        TEMPLATE.each do |section, keys|
          keys.each_key do |key|
            value = parsed.dig(section, key)
            if value.nil?
              raise MissingSettingError,
                "[#{section}] #{key} is not set in #{path}. Run `anima update` to add missing settings."
            end
            instance_variable_set(:"@#{section}_#{key}", value)
          end
        end
      end
    end
  end
end
