# frozen_string_literal: true

# Test helpers for Events::Bus. +capture_emissions+ installs a pass-through
# spy on {Events::Bus.emit} and returns an array that accumulates every event
# emitted after the call. Subscribers still run — the spy only observes.
module EventHelpers
  def capture_emissions
    emitted = []
    allow(Events::Bus).to receive(:emit).and_wrap_original do |original, event|
      emitted << event
      original.call(event)
    end
    emitted
  end
end

RSpec.configure do |config|
  config.include EventHelpers
end
