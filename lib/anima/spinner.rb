# frozen_string_literal: true

module Anima
  # Braille spinner for long-running CLI operations.
  # Animates in a background thread while a block executes in the
  # calling thread, then shows a success/failure indicator.
  #
  # @example
  #   result = Spinner.run("Installing...") { system("make install") }
  class Spinner
    FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze
    FRAME_DELAY = 0.08

    # Run a block with an animated spinner beside a status message.
    #
    # @param message [String] status text shown beside the spinner
    # @param output [IO] output stream (defaults to $stdout)
    # @yield the operation to run
    # @return [Object] the block's return value
    def self.run(message, output: $stdout, &block)
      new(message, output: output).run(&block)
    end

    # @param message [String] status text shown beside the spinner
    # @param output [IO] output stream
    def initialize(message, output: $stdout)
      @message = message
      @output = output
      @running = false
    end

    # @yield operation to run while the spinner animates
    # @return [Object] the block's return value
    def run
      thread = start_animation
      result = yield
      stop_animation(thread, success: !!result)
      result
    rescue
      stop_animation(thread, success: false)
      raise
    end

    private

    def start_animation
      @running = true
      Thread.new do
        idx = 0
        while @running
          @output.print "\r#{FRAMES[idx % FRAMES.size]} #{@message}"
          @output.flush
          idx += 1
          sleep FRAME_DELAY
        end
      end
    end

    def stop_animation(thread, success:)
      @running = false
      thread.join
      icon = success ? "\u2713" : "\u2717"
      @output.print "\r#{icon} #{@message}\n"
      @output.flush
    end
  end
end
