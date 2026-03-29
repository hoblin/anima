# frozen_string_literal: true

# Nanosecond conversion for Time objects. Replaces raw
# Process.clock_gettime(CLOCK_REALTIME) calls so that
# ActiveSupport's freeze_time / travel_to work in tests.
class Time
  # @return [Integer] nanoseconds since epoch
  def to_ns
    (to_r * 1_000_000_000).to_i
  end
end
