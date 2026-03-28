# frozen_string_literal: true

require "spec_helper"
require "tui/formatting"

RSpec.describe TUI::Formatting do
  subject(:formatter) { Object.new.extend(described_class) }

  describe "#token_count_color" do
    it "returns dark_gray for tokens under 1k" do
      expect(formatter.token_count_color(500)).to eq("dark_gray")
    end

    it "returns white for tokens between 1k and 3k" do
      expect(formatter.token_count_color(1_500)).to eq("white")
    end

    it "returns yellow for tokens between 3k and 10k" do
      expect(formatter.token_count_color(7_000)).to eq("yellow")
    end

    it "returns orange (208) for tokens between 10k and 20k" do
      expect(formatter.token_count_color(15_000)).to eq(208)
    end

    it "returns red for tokens over 20k" do
      expect(formatter.token_count_color(25_000)).to eq("red")
    end

    it "returns dark_gray at zero tokens" do
      expect(formatter.token_count_color(0)).to eq("dark_gray")
    end

    it "returns white at exactly 1000 tokens" do
      expect(formatter.token_count_color(1_000)).to eq("white")
    end

    it "returns yellow at exactly 3000 tokens" do
      expect(formatter.token_count_color(3_000)).to eq("yellow")
    end

    it "returns orange at exactly 10000 tokens" do
      expect(formatter.token_count_color(10_000)).to eq(208)
    end

    it "returns red at exactly 20000 tokens" do
      expect(formatter.token_count_color(20_000)).to eq("red")
    end
  end
end
