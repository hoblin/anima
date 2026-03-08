# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::SystemMessage do
  subject(:event) { described_class.new(content: "Session started") }

  it "has type system_message" do
    expect(event.type).to eq("system_message")
  end

  it "has correct event_name" do
    expect(event.event_name).to eq("anima.system_message")
  end
end
