# frozen_string_literal: true

module Tools
  # Executes bash commands in a persistent {ShellSession}. Commands share
  # working directory, environment variables, and shell history within a
  # conversation. Output is the rendered terminal text exactly as a human
  # would see it — including the prompt, which doubles as live cwd/branch
  # telemetry for the agent.
  #
  # Two input shapes:
  # - +command+ (string) — one command, one result.
  # - +commands+ (array) — runs each command in order in the same shell;
  #   all run regardless of failures (the agent reads merged output and
  #   decides what to do). Use shell chaining (+&&+) inside a single
  #   command if you need fail-fast.
  #
  # @see ShellSession#run
  class Bash < Base
    def self.tool_name = "bash"

    def self.description = "Execute shell commands. Working directory and environment persist between calls."

    def self.prompt_snippet = "Run shell commands."

    def self.prompt_guidelines = [
      "Working directory persists between bash calls — `cd` once or use absolute paths.",
      "For targeted text changes, prefer edit_file over `sed`/`awk` — exact-match replacement is safer than pattern matching.",
      "For reading files, prefer read_file over `cat`."
    ]

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
            description: "Each command gets its own timeout and result. All commands run regardless of failures — use a single command with shell chaining if you need fail-fast."
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
    # @return [String] rendered terminal output
    # @return [Hash] with :error key on failure
    def execute(input)
      timeout = input["timeout"]
      has_command = input.key?("command")
      has_commands = input.key?("commands")

      if has_command && has_commands
        {error: "Provide either 'command' or 'commands', not both"}
      elsif has_commands
        execute_batch(input["commands"], timeout: timeout)
      elsif has_command
        execute_single(input["command"], timeout: timeout)
      else
        {error: "Either 'command' (string) or 'commands' (array of strings) is required"}
      end
    end

    private

    # Executes a single command — the original code path.
    def execute_single(command, timeout: nil)
      command = command.to_s
      return {error: "Command cannot be blank"} if command.strip.empty?

      result = @shell_session.run(command, timeout: timeout, interrupt_check: interrupt_checker)

      return format_interrupted(result) if result[:interrupted]
      return result if result.key?(:error)

      result[:output]
    end

    # Executes an array of commands sequentially through the shared
    # shell. Continues past errors — the LLM reads the merged output
    # and decides what to do. The only short-circuit is a user interrupt,
    # which skips the remaining commands.
    #
    # @param commands [Array<String>] commands to execute
    # @param timeout [Integer, nil] per-command timeout override
    # @return [String] combined results with per-command headers
    # @return [Hash] with :error key if commands array is invalid
    def execute_batch(commands, timeout: nil)
      return {error: "Commands array cannot be empty"} unless commands.is_a?(Array) && commands.any?

      checker = interrupt_checker
      total = commands.size
      results = []
      interrupted = false

      commands.each_with_index do |command, index|
        position = "[#{index + 1}/#{total}]"

        if interrupted
          results << "#{position} $ #{command}\n(skipped — interrupted by user)"
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
        else
          results << "#{position} $ #{command}\n#{result[:output]}"
        end
      end

      results.join("\n\n")
    end

    # Formats the result of an interrupted command for the LLM.
    # Includes partial output captured before the interrupt.
    #
    # @param result [Hash] ShellSession result with :output key
    # @return [String] formatted message for the LLM
    def format_interrupted(result)
      output = result[:output].to_s
      parts = [LLM::Client::INTERRUPT_MESSAGE]
      parts << "Partial output:\n#{output}" unless output.empty?
      parts.join("\n\n")
    end

    # Builds a lambda that checks the database for a pending interrupt flag.
    # Called every {Anima::Settings.interrupt_check_interval} seconds during
    # command execution inside {ShellSession}.
    #
    # @return [Proc] lambda returning truthy when interrupt is pending
    def interrupt_checker
      session_id = @session.id
      -> { Session.where(id: session_id, interrupt_requested: true).exists? }
    end
  end
end
