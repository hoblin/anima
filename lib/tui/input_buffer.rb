# frozen_string_literal: true

module TUI
  # Manages editable text with cursor position tracking.
  # Supports multiline input with newline insertion, cursor navigation
  # across physical lines, and standard text editing operations.
  #
  # Pure logic object with no rendering or framework dependencies.
  class InputBuffer
    MAX_LENGTH = 10_000

    attr_reader :text, :cursor_pos

    def initialize
      @text = ""
      @cursor_pos = 0
    end

    # Resets the buffer to empty state.
    # @return [void]
    def clear
      @text = ""
      @cursor_pos = 0
    end

    # Returns stripped text and clears the buffer for message submission.
    # @return [String] the trimmed input text
    def consume
      content = @text.strip
      clear
      content
    end

    # @return [Boolean] whether the buffer contains any newline characters
    def multiline?
      @text.include?("\n")
    end

    # @return [Boolean] whether the buffer has reached MAX_LENGTH
    def full?
      @text.length >= MAX_LENGTH
    end

    # Ensures cursor stays within valid bounds after external state changes.
    # @return [void]
    def clamp_cursor
      @cursor_pos = @cursor_pos.clamp(0, @text.length)
    end

    # @param char [String] character(s) to insert at cursor
    # @return [Boolean] true if inserted, false if result would exceed MAX_LENGTH
    def insert(char)
      return false if @text.length + char.length > MAX_LENGTH

      @text = "#{@text[0...@cursor_pos]}#{char}#{@text[@cursor_pos..]}"
      @cursor_pos += char.length
      true
    end

    # @return [Boolean] true if a newline was inserted
    def newline
      return false if full?

      @text = "#{@text[0...@cursor_pos]}\n#{@text[@cursor_pos..]}"
      @cursor_pos += 1
      true
    end

    # Deletes the character before the cursor.
    # @return [Boolean] true if a character was deleted
    def backspace
      return false if @cursor_pos == 0

      @text = "#{@text[0...@cursor_pos - 1]}#{@text[@cursor_pos..]}"
      @cursor_pos -= 1
      true
    end

    # Deletes the character at the cursor (forward delete).
    # @return [Boolean] true if a character was deleted
    def delete
      return false if @cursor_pos >= @text.length

      @text = "#{@text[0...@cursor_pos]}#{@text[@cursor_pos + 1..]}"
      true
    end

    # @return [Boolean] true if cursor moved
    def move_left
      return false if @cursor_pos == 0

      @cursor_pos -= 1
      true
    end

    # @return [Boolean] true if cursor moved
    def move_right
      return false if @cursor_pos >= @text.length

      @cursor_pos += 1
      true
    end

    # Moves cursor to the start of the current physical line.
    # @return [Boolean] true if cursor moved
    def move_home
      return false if @cursor_pos == 0

      last_newline = @text.rindex("\n", @cursor_pos - 1)
      target = last_newline ? last_newline + 1 : 0
      return false if @cursor_pos == target

      @cursor_pos = target
      true
    end

    # Moves cursor to the end of the current physical line.
    # @return [Boolean] true if cursor moved
    def move_end
      newline_pos = @text.index("\n", @cursor_pos)
      target = newline_pos || @text.length
      return false if @cursor_pos == target

      @cursor_pos = target
      true
    end

    # Moves cursor up one physical line, preserving column position.
    # Clamps column to the target line's length when the previous line is shorter.
    # @return [Boolean] true if cursor moved
    def move_up
      line_idx, col = cursor_location
      return false if line_idx == 0

      lines = @text.split("\n", -1)
      prev_idx = line_idx - 1
      target_col = [col, lines[prev_idx].length].min
      @cursor_pos = line_start_positions[prev_idx] + target_col
      true
    end

    # Moves cursor down one physical line, preserving column position.
    # Clamps column to the target line's length when the next line is shorter.
    # @return [Boolean] true if cursor moved
    def move_down
      lines = @text.split("\n", -1)
      line_idx, col = cursor_location
      return false if line_idx >= lines.length - 1

      next_idx = line_idx + 1
      target_col = [col, lines[next_idx].length].min
      @cursor_pos = line_start_positions[next_idx] + target_col
      true
    end

    # @return [Array(Integer, Integer)] [line_index, column] for current cursor position
    def cursor_location
      return [0, 0] if @text.empty?

      lines = @text.split("\n", -1)
      pos = 0
      lines.each_with_index do |line, index|
        len = line.length
        return [index, @cursor_pos - pos] if @cursor_pos <= pos + len
        pos += len + 1
      end
      [lines.length - 1, lines.last.length]
    end

    # Maps each physical line to its starting offset within the text buffer.
    # Position after each newline marks the start of the next line.
    # @return [Array<Integer>] start position of each physical line
    def line_start_positions
      positions = [0]
      @text.each_char.with_index do |char, offset|
        positions << (offset + 1) if char == "\n"
      end
      positions
    end
  end
end
