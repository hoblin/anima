# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/tui/braille_spinner"

RSpec.describe TUI::BrailleSpinner do
  subject(:spinner) { described_class.new }

  describe "#state=" do
    it "starts idle" do
      expect(spinner.state).to eq("idle")
    end

    it "resets frame index on state change" do
      spinner.state = "llm_generating"
      3.times { spinner.tick }
      spinner.state = "tool_executing"

      # First tick after state change should be from the start of the tool frames
      char = spinner.current
      expect(char).to eq((TUI::BrailleSpinner::BRAILLE_BASE + TUI::BrailleSpinner::TOOL_FRAMES[0]).chr(Encoding::UTF_8))
    end

    it "does not reset frame index when state stays the same" do
      spinner.state = "llm_generating"
      3.times { spinner.tick }
      frame_before = spinner.current

      spinner.state = "llm_generating"
      expect(spinner.current).to eq(frame_before)
    end
  end

  describe "#tick" do
    it "returns nil when idle" do
      expect(spinner.tick).to be_nil
    end

    it "returns a single UTF-8 braille character when generating" do
      spinner.state = "llm_generating"
      char = spinner.tick

      expect(char).to be_a(String)
      expect(char.length).to eq(1)
      expect(char.ord).to be_between(0x2800, 0x28FF)
    end

    it "advances through frames for llm_generating" do
      spinner.state = "llm_generating"
      frames = 20.times.map { spinner.tick }

      # Should cycle (not all the same character)
      expect(frames.uniq.size).to be > 1
    end

    it "advances through frames for tool_executing" do
      spinner.state = "tool_executing"
      frames = 12.times.map { spinner.tick }

      expect(frames.uniq.size).to be > 1
    end

    it "advances through frames for interrupting" do
      spinner.state = "interrupting"
      frames = 12.times.map { spinner.tick }

      expect(frames.uniq.size).to be > 1
    end
  end

  describe "#current" do
    it "returns nil when idle" do
      expect(spinner.current).to be_nil
    end

    it "returns the current frame without advancing" do
      spinner.state = "llm_generating"
      spinner.tick

      a = spinner.current
      b = spinner.current
      expect(a).to eq(b)
    end
  end

  describe "#active?" do
    it "returns false when idle" do
      expect(spinner).not_to be_active
    end

    it "returns true when generating" do
      spinner.state = "llm_generating"
      expect(spinner).to be_active
    end

    it "returns true when tool executing" do
      spinner.state = "tool_executing"
      expect(spinner).to be_active
    end

    it "returns true when interrupting" do
      spinner.state = "interrupting"
      expect(spinner).to be_active
    end
  end

  describe "animation speed" do
    it "tool_executing animates faster than llm_generating" do
      expect(TUI::BrailleSpinner::SPEED["tool_executing"])
        .to be < TUI::BrailleSpinner::SPEED["llm_generating"]
    end
  end

  describe "frame sets" do
    it "all frames are valid braille dot patterns (0x00-0xFF)" do
      [
        TUI::BrailleSpinner::SNAKE_FRAMES,
        TUI::BrailleSpinner::SNAKE_TRAIL_FRAMES,
        TUI::BrailleSpinner::TOOL_FRAMES,
        TUI::BrailleSpinner::INTERRUPT_FRAMES
      ].each do |frames|
        frames.each do |frame|
          expect(frame).to be_between(0x00, 0xFF),
            "Frame #{frame.to_s(16)} is outside valid braille range"
        end
      end
    end
  end
end
