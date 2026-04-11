# frozen_string_literal: true

require "rails_helper"

RSpec.describe TokenEstimation do
  describe ".estimate_token_count" do
    it "divides byte size by BYTES_PER_TOKEN and rounds up" do
      expect(described_class.estimate_token_count("hello world")).to eq(3)
    end

    it "returns 0 for blank input" do
      expect(described_class.estimate_token_count("")).to eq(0)
      expect(described_class.estimate_token_count(nil)).to eq(0)
    end

    it "rounds up fractional token counts" do
      expect(described_class.estimate_token_count("a")).to eq(1)
    end

    it "counts multi-byte characters by byte size" do
      text = "héllo"
      expect(described_class.estimate_token_count(text)).to eq((text.bytesize / 4.0).ceil)
    end
  end

  describe "BYTES_PER_TOKEN" do
    it "is a small positive integer heuristic" do
      expect(described_class::BYTES_PER_TOKEN).to be_a(Integer)
      expect(described_class::BYTES_PER_TOKEN).to be > 0
    end
  end
end
