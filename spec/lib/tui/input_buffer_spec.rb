# frozen_string_literal: true

require "spec_helper"
require "tui/input_buffer"

RSpec.describe TUI::InputBuffer do
  subject(:buffer) { described_class.new }

  describe "#initialize" do
    it "starts with empty text" do
      expect(buffer.text).to eq("")
    end

    it "starts with cursor at 0" do
      expect(buffer.cursor_pos).to eq(0)
    end
  end

  describe "#insert" do
    it "inserts at cursor position and advances cursor" do
      buffer.insert("a")
      buffer.insert("b")
      expect(buffer.text).to eq("ab")
      expect(buffer.cursor_pos).to eq(2)
    end

    it "inserts in the middle of text" do
      buffer.insert("a")
      buffer.insert("c")
      buffer.move_left
      buffer.insert("b")
      expect(buffer.text).to eq("abc")
      expect(buffer.cursor_pos).to eq(2)
    end

    it "returns false when buffer is full" do
      buffer.instance_variable_set(:@text, "x" * described_class::MAX_LENGTH)
      buffer.instance_variable_set(:@cursor_pos, described_class::MAX_LENGTH)
      expect(buffer.insert("a")).to be false
    end

    it "returns true on success" do
      expect(buffer.insert("a")).to be true
    end
  end

  describe "#newline" do
    it "inserts newline at cursor" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.newline
      expect(buffer.text).to eq("ab\n")
      expect(buffer.cursor_pos).to eq(3)
    end

    it "inserts newline in the middle" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.move_left
      buffer.newline
      expect(buffer.text).to eq("a\nb")
      expect(buffer.cursor_pos).to eq(2)
    end

    it "returns false when full" do
      buffer.instance_variable_set(:@text, "x" * described_class::MAX_LENGTH)
      buffer.instance_variable_set(:@cursor_pos, described_class::MAX_LENGTH)
      expect(buffer.newline).to be false
    end
  end

  describe "#backspace" do
    it "deletes character before cursor" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.insert("c")
      buffer.backspace
      expect(buffer.text).to eq("ab")
      expect(buffer.cursor_pos).to eq(2)
    end

    it "deletes in the middle" do
      buffer.insert("a")
      buffer.insert("b")
      buffer.insert("c")
      buffer.move_left
      buffer.backspace
      expect(buffer.text).to eq("ac")
      expect(buffer.cursor_pos).to eq(1)
    end

    it "deletes newline characters" do
      buffer.insert("a")
      buffer.newline
      buffer.insert("b")
      buffer.move_left
      buffer.backspace
      expect(buffer.text).to eq("ab")
    end

    it "returns false at beginning" do
      expect(buffer.backspace).to be false
    end

    it "returns true on success" do
      buffer.insert("a")
      expect(buffer.backspace).to be true
    end
  end

  describe "#clear" do
    it "resets text and cursor" do
      buffer.insert("hello")
      buffer.clear
      expect(buffer.text).to eq("")
      expect(buffer.cursor_pos).to eq(0)
    end
  end

  describe "#consume" do
    it "returns stripped text and clears buffer" do
      buffer.insert(" ")
      buffer.insert("h")
      buffer.insert("i")
      buffer.insert(" ")

      result = buffer.consume
      expect(result).to eq("hi")
      expect(buffer.text).to eq("")
      expect(buffer.cursor_pos).to eq(0)
    end

    it "returns empty string for whitespace-only input" do
      buffer.insert(" ")
      buffer.insert(" ")
      expect(buffer.consume).to eq("")
    end
  end

  describe "#multiline?" do
    it "returns false for single-line text" do
      buffer.insert("hello")
      expect(buffer.multiline?).to be false
    end

    it "returns true when text contains newlines" do
      buffer.insert("hello")
      buffer.newline
      expect(buffer.multiline?).to be true
    end
  end

  describe "#move_left and #move_right" do
    before { buffer.insert("abc") }

    it "moves left" do
      expect(buffer.move_left).to be true
      expect(buffer.cursor_pos).to eq(2)
    end

    it "moves right after left" do
      buffer.move_left
      expect(buffer.move_right).to be true
      expect(buffer.cursor_pos).to eq(3)
    end

    it "returns false when at start" do
      buffer.instance_variable_set(:@cursor_pos, 0)
      expect(buffer.move_left).to be false
    end

    it "returns false when at end" do
      expect(buffer.move_right).to be false
    end

    it "crosses newline boundaries" do
      buffer.clear
      buffer.insert("a")
      buffer.newline
      buffer.insert("b")
      buffer.move_left
      buffer.move_left
      expect(buffer.cursor_pos).to eq(1)
    end
  end

  describe "#move_home and #move_end" do
    before do
      buffer.instance_variable_set(:@text, "hello\nworld")
      buffer.instance_variable_set(:@cursor_pos, 8)
    end

    it "moves to start of current line" do
      expect(buffer.move_home).to be true
      expect(buffer.cursor_pos).to eq(6)
    end

    it "moves to end of current line" do
      buffer.instance_variable_set(:@cursor_pos, 6)
      expect(buffer.move_end).to be true
      expect(buffer.cursor_pos).to eq(11)
    end

    it "moves to position 0 on first line" do
      buffer.instance_variable_set(:@cursor_pos, 3)
      expect(buffer.move_home).to be true
      expect(buffer.cursor_pos).to eq(0)
    end

    it "moves to end of input on last line" do
      buffer.instance_variable_set(:@cursor_pos, 7)
      expect(buffer.move_end).to be true
      expect(buffer.cursor_pos).to eq(11)
    end

    it "returns false when already at home" do
      buffer.instance_variable_set(:@cursor_pos, 6)
      expect(buffer.move_home).to be false
    end

    it "returns false when already at end of line" do
      buffer.instance_variable_set(:@cursor_pos, 11)
      expect(buffer.move_end).to be false
    end
  end

  describe "#move_up and #move_down" do
    before do
      buffer.instance_variable_set(:@text, "hello\nworld\nfoo")
      buffer.instance_variable_set(:@cursor_pos, 8)
    end

    it "moves up preserving column" do
      expect(buffer.move_up).to be true
      expect(buffer.cursor_pos).to eq(2)
    end

    it "moves down preserving column" do
      expect(buffer.move_down).to be true
      expect(buffer.cursor_pos).to eq(14)
    end

    it "clamps column to shorter line when moving up" do
      buffer.instance_variable_set(:@text, "hi\nworld")
      buffer.instance_variable_set(:@cursor_pos, 6)
      buffer.move_up
      expect(buffer.cursor_pos).to eq(2)
    end

    it "clamps column to shorter line when moving down" do
      buffer.instance_variable_set(:@text, "hello\nhi")
      buffer.instance_variable_set(:@cursor_pos, 4)
      buffer.move_down
      expect(buffer.cursor_pos).to eq(8)
    end

    it "returns false on first line going up" do
      buffer.instance_variable_set(:@cursor_pos, 2)
      expect(buffer.move_up).to be false
    end

    it "returns false on last line going down" do
      buffer.instance_variable_set(:@cursor_pos, 14)
      expect(buffer.move_down).to be false
    end

    it "handles empty lines" do
      buffer.instance_variable_set(:@text, "hello\n\nworld")
      buffer.instance_variable_set(:@cursor_pos, 3)
      buffer.move_down
      expect(buffer.cursor_pos).to eq(6)
    end
  end

  describe "#cursor_location" do
    it "returns [0, 0] for empty buffer" do
      expect(buffer.cursor_location).to eq([0, 0])
    end

    it "tracks position on first line" do
      buffer.instance_variable_set(:@text, "hello\nworld")
      buffer.instance_variable_set(:@cursor_pos, 3)
      expect(buffer.cursor_location).to eq([0, 3])
    end

    it "tracks position on second line" do
      buffer.instance_variable_set(:@text, "hello\nworld")
      buffer.instance_variable_set(:@cursor_pos, 8)
      expect(buffer.cursor_location).to eq([1, 2])
    end

    it "handles cursor at newline boundary" do
      buffer.instance_variable_set(:@text, "hello\nworld")
      buffer.instance_variable_set(:@cursor_pos, 5)
      expect(buffer.cursor_location).to eq([0, 5])
    end

    it "handles cursor at start of second line" do
      buffer.instance_variable_set(:@text, "hello\nworld")
      buffer.instance_variable_set(:@cursor_pos, 6)
      expect(buffer.cursor_location).to eq([1, 0])
    end
  end

  describe "#clamp_cursor" do
    it "clamps cursor to text length when out of bounds" do
      buffer.insert("hi")
      buffer.instance_variable_set(:@cursor_pos, 99)
      buffer.clamp_cursor
      expect(buffer.cursor_pos).to eq(2)
    end

    it "clamps negative cursor to 0" do
      buffer.instance_variable_set(:@cursor_pos, -5)
      buffer.clamp_cursor
      expect(buffer.cursor_pos).to eq(0)
    end
  end
end
