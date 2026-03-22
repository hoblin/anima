# frozen_string_literal: true

require "spec_helper"
require "anima/spinner"

RSpec.describe Anima::Spinner do
  let(:output) { StringIO.new }

  describe ".run" do
    it "returns the block's result" do
      result = described_class.run("Working...", output: output) { 42 }

      expect(result).to eq(42)
    end

    it "shows a success indicator when the block returns truthy" do
      described_class.run("Installing...", output: output) { true }

      expect(output.string).to include("\u2713 Installing...")
    end

    it "shows a failure indicator when the block returns falsy" do
      described_class.run("Updating...", output: output) { false }

      expect(output.string).to include("\u2717 Updating...")
    end

    it "shows a failure indicator when the block raises" do
      expect {
        described_class.run("Breaking...", output: output) { raise "boom" }
      }.to raise_error(RuntimeError, "boom")

      expect(output.string).to include("\u2717 Breaking...")
    end

    it "re-raises the original exception" do
      expect {
        described_class.run("Failing...", output: output) { raise ArgumentError, "bad arg" }
      }.to raise_error(ArgumentError, "bad arg")
    end

    it "renders at least one spinner frame during a slow operation" do
      described_class.run("Waiting...", output: output) { sleep 0.15 }

      expect(output.string).to match(/[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏] Waiting\.\.\./)
    end

    it "ends the output line with a newline" do
      described_class.run("Done.", output: output) { true }

      expect(output.string).to end_with("\n")
    end
  end
end
