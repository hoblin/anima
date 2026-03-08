# frozen_string_literal: true

require "spec_helper"
require "tui/screens/chat"

RSpec.describe TUI::Screens::Chat do
  subject(:screen) { described_class.new }

  it "does not respond to handle_event" do
    expect(screen).not_to respond_to(:handle_event)
  end
end
