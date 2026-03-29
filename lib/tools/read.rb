# frozen_string_literal: true

module Tools
  # Reads file contents with smart truncation and offset/limit paging.
  # Returns plain text without line numbers, normalized to LF line endings.
  #
  # Truncation limits: `Anima::Settings.max_read_lines` lines or `Anima::Settings.max_read_bytes` bytes, whichever
  # hits first. When truncated, appends a continuation hint with the next
  # offset value so the agent can page through large files.
  #
  # @example Basic read
  #   tool.execute("path" => "config/routes.rb")
  #   # => "Rails.application.routes.draw do\n  ..."
  #
  # @example Paging through a large file
  #   tool.execute("path" => "large.log", "offset" => 2001, "limit" => 500)
  #   # => "line 2001 content\n..."
  class Read < Base
    def self.tool_name = "read_file"
    def self.truncation_threshold = nil

    def self.description = "Read file. Relative paths resolve against working directory."

    def self.input_schema
      {
        type: "object",
        properties: {
          path: {type: "string"},
          offset: {type: "integer", description: "1-indexed line number (default: 1)."},
          limit: {type: "integer", description: "Max lines to return."}
        },
        required: ["path"]
      }
    end

    # @param shell_session [ShellSession, nil] provides working directory for resolving relative paths
    def initialize(shell_session: nil, **)
      @working_directory = shell_session&.pwd
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API
    # @return [String] file contents (possibly truncated with continuation hint)
    # @return [Hash] with :error key on failure
    def execute(input)
      path, offset, limit = extract_params(input)
      return {error: "Path cannot be blank"} if path.empty?

      path = resolve_path(path)

      error = validate_file(path)
      return error if error

      read_file(path, offset, limit)
    end

    private

    def extract_params(input)
      path = input["path"].to_s.strip
      offset = [input["offset"].to_i, 1].max
      raw_limit = input["limit"]
      limit = raw_limit ? [raw_limit.to_i, 1].max : Anima::Settings.max_read_lines
      [path, offset, limit]
    end

    def resolve_path(path)
      if @working_directory
        File.expand_path(path, @working_directory)
      else
        File.expand_path(path)
      end
    end

    def validate_file(path)
      return {error: "File not found: #{path}"} unless File.exist?(path)
      return {error: "Is a directory: #{path}"} if File.directory?(path)
      {error: "Permission denied: #{path}"} unless File.readable?(path)
    end

    # Reads the file, normalizes line endings, and applies truncation limits.
    # Two limits are enforced as first-hit-wins: line count and byte size.
    # A single line exceeding `Anima::Settings.max_read_bytes` is rejected outright (likely minified).
    # Files larger than max_file_size are rejected to avoid memory exhaustion.

    def read_file(path, offset, limit)
      file_size = File.size(path)
      max_size = Anima::Settings.max_file_size
      if file_size > max_size
        return {error: "File is #{file_size} bytes (#{file_size / 1_048_576} MB). " \
                       "Max readable size is #{max_size / 1_048_576} MB. " \
                       "Use bash tool with: head -n #{offset + limit} #{path} | tail -n +#{offset}"}
      end

      lines = normalize(File.read(path))
      return "" if lines.empty?

      start_index = offset - 1
      return "[File has #{lines.size} lines. Offset #{offset} is beyond end of file.]" if start_index >= lines.size

      window = lines[start_index, [limit, Anima::Settings.max_read_lines].min]

      error = check_oversized_lines(window, offset, path)
      return error if error

      build_output(window, lines.size, offset)
    end

    def normalize(content)
      content.gsub("\r\n", "\n").lines
    end

    def check_oversized_lines(window, offset, path)
      max_bytes = Anima::Settings.max_read_bytes
      index = window.index { |line| line.bytesize > max_bytes }
      return unless index

      line_num = offset + index
      {error: "Line #{line_num} exceeds #{max_bytes} bytes (likely minified). " \
              "Use bash tool with: sed -n '#{line_num}p' #{path}"}
    end

    def build_output(window, total_lines, offset)
      text, count = accumulate_lines(window)
      end_line = offset + count - 1

      if end_line < total_lines
        text + "\n\n[Showing lines #{offset}-#{end_line} of #{total_lines}. Use offset=#{end_line + 1} to continue.]"
      else
        text
      end
    end

    # Accumulates lines until the byte cap would be exceeded.
    # @return [Array(String, Integer)] accumulated text and number of lines included
    def accumulate_lines(window)
      max_bytes = Anima::Settings.max_read_bytes
      output = +""
      bytes = 0
      count = 0

      window.each_with_index do |line, index|
        break if bytes + line.bytesize > max_bytes && index > 0

        output << line
        bytes += line.bytesize
        count += 1
      end

      [output, count]
    end
  end
end
