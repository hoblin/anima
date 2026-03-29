# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ResponseTruncator do
  describe ".truncate" do
    let(:threshold) { 200 }

    context "when content is under threshold" do
      it "returns the original content unchanged" do
        content = "short output"
        expect(described_class.truncate(content, threshold: threshold)).to eq(content)
      end

      it "returns empty string unchanged" do
        expect(described_class.truncate("", threshold: threshold)).to eq("")
      end

      it "returns content unchanged when exactly at threshold" do
        content = "x" * threshold
        expect(described_class.truncate(content, threshold: threshold)).to eq(content)
      end
    end

    context "when content is not a string" do
      it "returns nil unchanged" do
        expect(described_class.truncate(nil, threshold: threshold)).to be_nil
      end

      it "returns integers unchanged" do
        expect(described_class.truncate(42, threshold: threshold)).to eq(42)
      end
    end

    context "when content exceeds threshold but has few lines" do
      it "returns content unchanged when total lines <= head + tail" do
        content = "x" * 300 # long single line
        expect(described_class.truncate(content, threshold: threshold)).to eq(content)
      end

      it "returns content unchanged at exactly head + tail lines" do
        lines = (1..20).map { |n| "Line #{n}\n" }.join
        expect(described_class.truncate(lines, threshold: 10)).to eq(lines)
      end
    end

    context "when content exceeds threshold and has enough lines" do
      let(:content) { (1..100).map { |n| "Line #{n}: some content here\n" }.join }

      subject(:result) { described_class.truncate(content, threshold: 50) }

      it "includes the first 10 lines" do
        (1..10).each do |n|
          expect(result).to include("Line #{n}:")
        end
      end

      it "includes the last 10 lines" do
        (91..100).each do |n|
          expect(result).to include("Line #{n}:")
        end
      end

      it "excludes middle lines" do
        expect(result).not_to include("Line 50:")
      end

      it "includes truncation notice with line count" do
        expect(result).to include("⚠️ Response truncated (100 lines total)")
      end

      it "omits reason dash when no reason given" do
        expect(result).not_to include("—")
      end

      it "includes the temp file path" do
        expect(result).to match(%r{Full output saved to: .+/tool_result_.+\.txt})
      end

      it "includes read tool hint" do
        expect(result).to include("Use `read` tool with offset/limit")
      end

      it "saves full content to the temp file" do
        path = result.match(%r{saved to: (.+\.txt)})[1]
        expect(File.read(path)).to eq(content)
      end
    end

    context "when a reason is provided" do
      let(:content) { (1..100).map { |n| "Line #{n}: some content here\n" }.join }

      subject(:result) do
        described_class.truncate(content, threshold: 50, reason: "bash output displays first/last 10 lines")
      end

      it "includes the reason in the truncation notice" do
        expect(result).to include("100 lines total — bash output displays first/last 10 lines")
      end
    end

    context "with default tool threshold from settings" do
      it "uses max_tool_response_chars setting" do
        big = "x\n" * 2000
        result = described_class.truncate(big, threshold: Anima::Settings.max_tool_response_chars)
        expect(result).to include("⚠️ Response truncated")
      end
    end

    context "with sub-agent threshold from settings" do
      it "uses max_subagent_response_chars setting" do
        # 24000 chars is the sub-agent threshold — content under it should pass through
        content = "x\n" * 1000 # 2000 chars
        result = described_class.truncate(content, threshold: Anima::Settings.max_subagent_response_chars)
        expect(result).to eq(content)
      end
    end
  end

  describe ".save_full_output" do
    it "writes content to a temp file and returns the path" do
      content = "full tool output here"
      path = described_class.save_full_output(content)

      expect(File.exist?(path)).to be true
      expect(File.read(path)).to eq(content)
    end

    it "creates files with tool_result_ prefix" do
      path = described_class.save_full_output("test")
      expect(File.basename(path)).to match(/\Atool_result_/)
    end

    it "creates files with .txt extension" do
      path = described_class.save_full_output("test")
      expect(path).to end_with(".txt")
    end
  end
end
