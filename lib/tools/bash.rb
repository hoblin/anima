# frozen_string_literal: true

module Tools
  # Executes bash commands in a persistent {ShellSession}. Commands share
  # working directory, environment variables, and shell history within a
  # conversation. Output is truncated and timeouts are enforced by the
  # underlying session.
  #
  # Supports two modes:
  # - Single command via +command+ (string) — backward compatible
  # - Batch via +commands+ (array) with +mode+ controlling error handling
  #
  # @see ShellSession#run
  class Bash < Base
    def self.tool_name = "bash"

    def self.description = "Execute shell commands. Working directory and environment persist between calls."

    def self.input_schema
      {
        type: "object",
        properties: {
          command: {
            type: "string"
          },
          commands: {
            type: "array",
            items: {type: "string"},
            description: "Each command gets its own timeout and result."
          },
          mode: {
            type: "string",
            enum: ["sequential", "parallel"],
            description: "sequential (default) stops on first failure."
          }
        }
      }
    end

    # @param shell_session [ShellSession] persistent shell backing this tool
    # @param session [Session] conversation session for interrupt checking
    def initialize(shell_session:, session:, **)
      @shell_session = shell_session
      @session = session
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API.
    #   Supports optional "timeout" key (seconds) to override the global
    #   command_timeout setting for long-running operations.
    # @return [String] formatted output with stdout, stderr, and exit code
    # @return [Hash] with :error key on failure
    def execute(input)
      timeout = input["timeout"]
      has_command = input.key?("command")
      has_commands = input.key?("commands")

      if has_command && has_commands
        {error: "Provide either 'command' or 'commands', not both"}
      elsif has_commands
        execute_batch(input["commands"], mode: input.fetch("mode", "sequential"), timeout: timeout)
      elsif has_command
        execute_single(input["command"], timeout: timeout)
      else
        {error: "Either 'command' (string) or 'commands' (array of strings) is required"}
      end
    end

    private

    # Executes a single command — the original code path, preserved for backward compatibility.
    def execute_single(command, timeout: nil)
      command = command.to_s
      return {error: "Command cannot be blank"} if command.strip.empty?

      result = @shell_session.run(command, timeout: timeout, interrupt_check: interrupt_checker)

      return format_interrupted(result) if result[:interrupted]
      return result if result.key?(:error)

      format_result(result[:stdout], result[:stderr], result[:exit_code])
    end

    # Executes an array of commands, returning a combined result string.
    # Checks for user interrupt between commands and during each command
    # via the {ShellSession} interrupt_check callback.
    #
    # @param commands [Array<String>] commands to execute
    # @param mode [String] "sequential" (stop on first failure) or "parallel" (run all)
    # @param timeout [Integer, nil] per-command timeout override
    # @return [String] combined results with per-command headers
    # @return [Hash] with :error key if commands array is invalid
    def execute_batch(commands, mode:, timeout: nil)
      return {error: "Commands array cannot be empty"} unless commands.is_a?(Array) && commands.any?

      checker = interrupt_checker
      total = commands.size
      results = []
      failed = false
      interrupted = false

      commands.each_with_index do |command, index|
        position = "[#{index + 1}/#{total}]"

        if interrupted
          results << "#{position} $ #{command}\n(skipped — interrupted by user)"
          next
        end

        if failed && mode == "sequential"
          results << "#{position} $ #{command}\n(skipped)"
          next
        end

        command = command.to_s
        if command.strip.empty?
          results << "#{position} $ (blank)\n(skipped — blank command)"
          next
        end

        result = @shell_session.run(command, timeout: timeout, interrupt_check: checker)

        if result[:interrupted]
          results << "#{position} $ #{command}\n#{format_interrupted(result)}"
          interrupted = true
        elsif result.key?(:error)
          results << "#{position} $ #{command}\n#{result[:error]}"
          failed = true
        else
          exit_code = result[:exit_code]
          output = format_result(result[:stdout], result[:stderr], exit_code)
          results << "#{position} $ #{command}\n#{output}"
          failed = true if exit_code != 0
        end
      end

      results.join("\n\n")
    end

    def format_result(stdout, stderr, exit_code)
      parts = []
      parts << "stdout:\n#{stdout}" unless stdout.empty?
      parts << "stderr:\n#{stderr}" unless stderr.empty?
      parts << "exit_code: #{exit_code}"
      parts.join("\n\n")
    end

    # Formats the result of an interrupted command for the LLM.
    # Includes partial output captured before the interrupt.
    def format_interrupted(result)
      stdout = result[:stdout].to_s
      stderr = result[:stderr].to_s
      parts = ["Your human wants your attention."]
      parts << "Partial stdout:\n#{stdout}" unless stdout.empty?
      parts << "stderr:\n#{stderr}" unless stderr.empty?
      parts.join("\n\n")
    end

    # Builds a lambda that checks the database for a pending interrupt flag.
    # Called every {Anima::Settings.interrupt_check_interval} seconds during
    # command execution inside {ShellSession}.
    def interrupt_checker
      session_id = @session.id
      -> { Session.where(id: session_id, interrupt_requested: true).exists? }
    end
  end
end
