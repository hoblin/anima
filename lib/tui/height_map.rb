# frozen_string_literal: true

module TUI
  # Tracks estimated visual heights for chat entries, enabling
  # viewport virtualization. Heights are in visual (wrapped) line
  # units, estimated from content length and terminal width.
  #
  # Provides efficient scroll-position-to-entry-index mapping so
  # the chat screen can render only visible messages instead of
  # processing the entire conversation history.
  #
  # @example
  #   map = HeightMap.new
  #   map.update(entries, 80) { |entry, width| estimate(entry, width) }
  #   first, last = map.visible_range(scroll_offset, viewport_height)
  #   total = map.total_height
  class HeightMap
    # @return [Integer] number of tracked entries
    attr_reader :size

    def initialize
      @heights = []
      @size = 0
    end

    # Replaces all heights from a fresh estimation pass.
    # Each entry's height is computed by the caller-supplied block.
    #
    # @param entries [Array<Hash>] message store entries
    # @param width [Integer] terminal width for wrap estimation
    # @yield [entry, width] block returning estimated visual line count
    # @return [void]
    def update(entries, width)
      @heights = entries.map { |entry| [yield(entry, width), 1].max }
      @size = @heights.size
    end

    # @return [Integer] sum of all estimated entry heights
    def total_height
      @heights.sum(0)
    end

    # Cumulative height of entries before the given index.
    #
    # @param index [Integer] entry index (0-based)
    # @return [Integer] total visual lines above this entry
    def cumulative_height(index)
      return 0 if index <= 0 || @heights.empty?
      return @heights.sum(0) if index >= @size

      @heights[0...index].sum(0)
    end

    # Finds the entry range visible within a scroll window.
    # An entry is visible if any of its lines fall within
    # [scroll_offset, scroll_offset + visible_height).
    #
    # @param scroll_offset [Integer] top of viewport in visual lines
    # @param visible_height [Integer] viewport height in visual lines
    # @return [Array(Integer, Integer)] [first_visible, last_visible]
    def visible_range(scroll_offset, visible_height)
      return [0, 0] if @heights.empty?

      first_found = false
      first = 0
      last = 0
      cumulative = 0
      end_line = scroll_offset + visible_height

      @heights.each_with_index do |entry_height, idx|
        entry_end = cumulative + entry_height
        unless first_found
          if entry_end > scroll_offset
            first = idx
            first_found = true
          end
        end
        last = idx if cumulative < end_line
        cumulative = entry_end
      end

      first = [@size - 1, 0].max unless first_found
      [first, [last, first].max]
    end

    # Clears all tracked heights.
    # @return [void]
    def reset
      @heights.clear
      @size = 0
    end
  end
end
