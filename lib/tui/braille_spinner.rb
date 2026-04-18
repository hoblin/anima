# frozen_string_literal: true

module TUI
  # Animated braille spinner that communicates session state through distinct
  # visual patterns. Each state gets its own animation — a user watching long
  # enough starts _feeling_ the difference between LLM thinking and tool
  # execution without reading text.
  #
  # The 2x4 braille grid (U+2800-U+28FF) encodes 8 dots in a single character
  # cell. Dot positions map to bit flags:
  #
  #   ┌───┬───┐
  #   │ 0 │ 3 │   bit 0 = top-left,     bit 3 = top-right
  #   │ 1 │ 4 │   bit 1 = mid-left,     bit 4 = mid-right
  #   │ 2 │ 5 │   bit 2 = lower-left,   bit 5 = lower-right
  #   │ 6 │ 7 │   bit 6 = bottom-left,  bit 7 = bottom-right
  #   └───┴───┘
  #
  # During LLM generation, a snake weaves through the grid — organic,
  # unpredictable movement like watching a campfire. During tool execution,
  # a fast staccato pulse signals mechanical work. Interrupting decelerates
  # to a freeze.
  #
  # @example Basic usage
  #   spinner = BrailleSpinner.new
  #   spinner.state = "awaiting"
  #   char = spinner.tick  # => "⠋" (braille pattern)
  class BrailleSpinner
    # Clockwise traversal of the 8 dots in the braille grid.
    # Produces a smooth rotating animation — one dot lit at a time.
    SNAKE_FRAMES = [
      0x01, # ⠁ dot 0 (top-left)
      0x02, # ⠂ dot 1 (mid-left)
      0x04, # ⠄ dot 2 (lower-left)
      0x40, # ⡀ dot 6 (bottom-left)
      0x80, # ⢀ dot 7 (bottom-right)
      0x20, # ⠠ dot 5 (lower-right)
      0x10, # ⠐ dot 4 (mid-right)
      0x08  # ⠈ dot 3 (top-right)
    ].freeze

    # Snake animation: 3 consecutive dots form a growing/moving tail.
    # Each frame is the OR of 3 adjacent positions in SNAKE_FRAMES,
    # creating a worm-like creature circling the grid.
    SNAKE_TRAIL_FRAMES = SNAKE_FRAMES.each_index.map { |idx|
      SNAKE_FRAMES[idx] | SNAKE_FRAMES[(idx + 1) % 8] | SNAKE_FRAMES[(idx + 2) % 8]
    }.freeze

    # Tool execution: alternating dot patterns for a staccato pulse.
    # Fast, mechanical, clearly different from the smooth snake.
    TOOL_FRAMES = [
      0x09, # ⠉ dots 0+3 (top row)
      0x12, # ⠒ dots 1+4 (middle row)
      0x24, # ⠤ dots 2+5 (lower row)
      0xC0, # ⣀ dots 6+7 (bottom row)
      0x24, # ⠤ dots 2+5 (lower row)
      0x12  # ⠒ dots 1+4 (middle row)
    ].freeze

    # Interrupting: rapid deceleration — full grid fading to empty.
    INTERRUPT_FRAMES = [
      0xFF, # ⣿ all dots
      0xDB, # ⣛ most dots
      0x49, # ⡉ sparse
      0x00, # ⠀ empty
      0x49, # ⡉ sparse
      0xFF  # ⣿ all dots
    ].freeze

    # Braille Unicode block base codepoint.
    BRAILLE_BASE = 0x2800

    # Ticks per frame for each state — controls animation speed.
    # Higher = slower. At ~15fps render loop: 2 = ~7.5fps, 4 = ~3.75fps.
    SPEED = {
      "awaiting" => 2,
      "executing" => 1,
      "interrupting" => 1
    }.freeze

    # @return [String] current session state
    attr_reader :state

    def initialize
      @state = "idle"
      @frame_index = 0
      @tick_count = 0
    end

    # Updates the session state driving the animation.
    # Resets frame position on state change for a clean transition.
    #
    # @param new_state [String] one of "idle", "awaiting",
    #   "executing", "interrupting"
    def state=(new_state)
      if @state != new_state
        @frame_index = 0
        @tick_count = 0
      end
      @state = new_state
    end

    # Advances the animation by one tick and returns the current
    # braille character. Returns nil when idle (no animation).
    #
    # @return [String, nil] single braille character, or nil when idle
    def tick
      return nil if @state == "idle"

      frames = frames_for_state
      return nil unless frames

      speed = SPEED.fetch(@state, 2)
      @tick_count += 1
      if @tick_count >= speed
        @tick_count = 0
        @frame_index = (@frame_index + 1) % frames.size
      end

      (BRAILLE_BASE + frames[@frame_index]).chr(Encoding::UTF_8)
    end

    # Returns the current frame character without advancing.
    #
    # @return [String, nil] single braille character, or nil when idle
    def current
      return nil if @state == "idle"

      frames = frames_for_state
      return nil unless frames

      (BRAILLE_BASE + frames[@frame_index]).chr(Encoding::UTF_8)
    end

    # Whether the spinner is actively animating.
    #
    # @return [Boolean]
    def active?
      @state != "idle"
    end

    private

    def frames_for_state
      case @state
      when "awaiting" then SNAKE_TRAIL_FRAMES
      when "executing" then TOOL_FRAMES
      when "interrupting" then INTERRUPT_FRAMES
      end
    end
  end
end
