# frozen_string_literal: true

require "spec_helper"
require "ratatui_ruby"
require "tui/screens/settings"

RSpec.describe TUI::Screens::Settings do
  subject(:screen) { described_class.new }

  describe "MENU_ITEMS" do
    it "has navigable menu entries" do
      expect(described_class::MENU_ITEMS).to include("General", "Appearance", "Keybindings")
    end

    it "is frozen" do
      expect(described_class::MENU_ITEMS).to be_frozen
    end
  end

  describe "#handle_event" do
    context "before first render" do
      it "returns false when list_state is not initialized" do
        event = double("Event", down?: true, j?: false)
        expect(screen.handle_event(event)).to be false
      end
    end
  end
end
