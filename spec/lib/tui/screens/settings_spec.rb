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

    context "after list_state is initialized" do
      let(:list_state) { double("ListState", select_next: nil, select_previous: nil) }

      before { screen.instance_variable_set(:@list_state, list_state) }

      it "selects next on down arrow" do
        event = double("Event", down?: true, j?: false, up?: false, k?: false)
        expect(screen.handle_event(event)).to be true
        expect(list_state).to have_received(:select_next)
      end

      it "selects next on j" do
        event = double("Event", down?: false, j?: true, up?: false, k?: false)
        expect(screen.handle_event(event)).to be true
        expect(list_state).to have_received(:select_next)
      end

      it "selects previous on up arrow" do
        event = double("Event", down?: false, j?: false, up?: true, k?: false)
        expect(screen.handle_event(event)).to be true
        expect(list_state).to have_received(:select_previous)
      end

      it "selects previous on k" do
        event = double("Event", down?: false, j?: false, up?: false, k?: true)
        expect(screen.handle_event(event)).to be true
        expect(list_state).to have_received(:select_previous)
      end

      it "returns false for unrecognized keys" do
        event = double("Event", down?: false, j?: false, up?: false, k?: false)
        expect(screen.handle_event(event)).to be false
      end
    end
  end
end
