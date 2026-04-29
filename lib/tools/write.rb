# frozen_string_literal: true

require "fileutils"

module Tools
  # Creates or overwrites files with automatic intermediate directory creation.
  # Writes content exactly as given — no line ending normalization, no BOM
  # handling. Full replacement only; no append or merge.
  #
  # @example Creating a new file
  #   tool.execute("path" => "config/new.yml", "content" => "key: value\n")
  #   # => "Wrote 11 bytes to /home/user/project/config/new.yml"
  #
  # @example Overwriting an existing file
  #   tool.execute("path" => "README.md", "content" => "# Title\n")
  #   # => "Wrote 9 bytes to /home/user/project/README.md"
  class Write < Base
    def self.tool_name = "write_file"

    def self.description = "Write file."

    def self.prompt_snippet = "Create or overwrite a whole file."

    def self.prompt_guidelines = [
      "write_file replaces the whole file. For targeted changes, use edit_file."
    ]

    def self.input_schema
      {
        type: "object",
        properties: {
          path: {type: "string", description: "Relative paths resolve against working directory. Creates intermediate directories."},
          content: {type: "string"}
        },
        required: %w[path content]
      }
    end

    # @param shell_session [ShellSession, nil] provides working directory for resolving relative paths
    def initialize(shell_session: nil, **)
      @working_directory = shell_session&.pwd
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API
    # @return [String] confirmation with bytes written and resolved path
    # @return [Hash] with :error key on failure
    def execute(input)
      path, content = extract_params(input)
      return {error: "Path cannot be blank"} if path.empty?

      path = resolve_path(path)

      error = validate_target(path)
      return error if error

      write_file(path, content)
    end

    private

    def extract_params(input)
      path = input["path"].to_s.strip
      content = input["content"].to_s
      [path, content]
    end

    def resolve_path(path)
      if @working_directory
        File.expand_path(path, @working_directory)
      else
        File.expand_path(path)
      end
    end

    def validate_target(path)
      return {error: "Is a directory: #{path}"} if File.directory?(path)
      {error: "Not writable: #{path}"} if File.exist?(path) && !File.writable?(path)
    end

    def write_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      bytes = File.write(path, content)
      "Wrote #{bytes} bytes to #{path}"
    rescue Errno::EACCES
      {error: "Permission denied: #{path}"}
    rescue Errno::ENOSPC
      {error: "No space left on device: #{path}"}
    rescue Errno::EROFS
      {error: "Read-only file system: #{path}"}
    end
  end
end
