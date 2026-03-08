# frozen_string_literal: true

require "open3"
require "timeout"

module Tools
  # Executes a bash command in a fresh shell and returns stdout, stderr,
  # and exit code. Each invocation is stateless — no state is carried
  # between calls.
  #
  # Output is truncated to {MAX_OUTPUT_BYTES} per stream to prevent
  # memory issues. Commands are killed after {COMMAND_TIMEOUT} seconds.
  class Bash < Base
    MAX_OUTPUT_BYTES = 100_000
    COMMAND_TIMEOUT = 30

    def self.tool_name = "bash"

    def self.description = "Execute a bash command and return stdout, stderr, and exit code"

    def self.input_schema
      {
        type: "object",
        properties: {
          command: {type: "string", description: "The bash command to execute"}
        },
        required: ["command"]
      }
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API
    # @return [String] formatted output with stdout, stderr, and exit code
    # @return [Hash] with :error key on failure
    def execute(input)
      command = input["command"].to_s
      return {error: "Command cannot be blank"} if command.strip.empty?

      run_command(command)
    end

    private

    def run_command(command)
      Timeout.timeout(COMMAND_TIMEOUT) do
        # Close stdin immediately so interactive commands don't hang
        stdout, stderr, status = Open3.capture3("bash", "-c", command, stdin_data: "")
        format_result(truncate(stdout), truncate(stderr), status.exitstatus)
      end
    rescue Timeout::Error
      {error: "Command timed out after #{COMMAND_TIMEOUT} seconds"}
    rescue => error
      {error: "#{error.class}: #{error.message}"}
    end

    def format_result(stdout, stderr, exit_code)
      parts = []
      parts << "stdout:\n#{stdout}" unless stdout.empty?
      parts << "stderr:\n#{stderr}" unless stderr.empty?
      parts << "exit_code: #{exit_code}"
      parts.join("\n\n")
    end

    def truncate(output)
      return output if output.bytesize <= MAX_OUTPUT_BYTES

      output.byteslice(0, MAX_OUTPUT_BYTES)
        .force_encoding("UTF-8")
        .scrub +
        "\n\n[Truncated: output exceeded #{MAX_OUTPUT_BYTES} bytes]"
    end
  end
end
