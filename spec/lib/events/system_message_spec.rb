# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::SystemMessage do
  it "serialises as system_message with its content" do
    event = described_class.new(content: "Session started")
    expect(event.to_h).to include(type: "system_message", content: "Session started")
  end
end
