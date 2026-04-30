# frozen_string_literal: true

require "rails_helper"

RSpec.describe Aoide::PhantomCallFilter do
  describe ".call" do
    it "returns the response unchanged when content has no tool_use blocks" do
      response = {"content" => [{"type" => "text", "text" => "hello"}]}

      expect(described_class.call(response)).to be(response)
    end

    it "returns the response unchanged when no tool_use is from_*-named" do
      response = {"content" => [
        {"type" => "tool_use", "id" => "toolu_1", "name" => "bash", "input" => {}}
      ]}

      expect(described_class.call(response)).to be(response)
    end

    it "drops tool_use blocks whose name starts with from_" do
      response = {"content" => [
        {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_shell-runner", "input" => {}}
      ]}

      filtered = described_class.call(response)

      expect(filtered["content"]).to eq([])
    end

    it "preserves text blocks alongside dropped from_* tool_use blocks" do
      response = {"content" => [
        {"type" => "text", "text" => "thinking out loud"},
        {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_melete_goal", "input" => {}}
      ]}

      filtered = described_class.call(response)

      expect(filtered["content"]).to eq([
        {"type" => "text", "text" => "thinking out loud"}
      ])
    end

    it "preserves legitimate tool_use blocks alongside dropped from_* blocks" do
      response = {"content" => [
        {"type" => "tool_use", "id" => "toolu_real", "name" => "bash", "input" => {"command" => "ls"}},
        {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_zero-width-sleuth", "input" => {}}
      ]}

      filtered = described_class.call(response)

      expect(filtered["content"]).to eq([
        {"type" => "tool_use", "id" => "toolu_real", "name" => "bash", "input" => {"command" => "ls"}}
      ])
    end

    it "drops every from_* block when multiple are present" do
      response = {"content" => [
        {"type" => "tool_use", "id" => "p1", "name" => "from_a", "input" => {}},
        {"type" => "text", "text" => "between them"},
        {"type" => "tool_use", "id" => "p2", "name" => "from_b", "input" => {}}
      ]}

      filtered = described_class.call(response)

      expect(filtered["content"]).to eq([
        {"type" => "text", "text" => "between them"}
      ])
    end

    it "leaves the original response object untouched (does not mutate)" do
      original_content = [
        {"type" => "tool_use", "id" => "toolu_phantom", "name" => "from_shell-runner", "input" => {}}
      ]
      response = {"content" => original_content, "stop_reason" => "tool_use"}

      described_class.call(response)

      expect(response["content"]).to be(original_content)
      expect(response["content"].size).to eq(1)
    end

    it "carries non-content keys through unchanged" do
      response = {
        "content" => [{"type" => "tool_use", "id" => "p1", "name" => "from_x", "input" => {}}],
        "stop_reason" => "tool_use",
        "usage" => {"input_tokens" => 42}
      }

      filtered = described_class.call(response)

      expect(filtered["stop_reason"]).to eq("tool_use")
      expect(filtered["usage"]).to eq({"input_tokens" => 42})
    end

    it "tolerates a missing content key" do
      response = {"stop_reason" => "end_turn"}

      expect(described_class.call(response)).to eq("stop_reason" => "end_turn")
    end

    it "tolerates a non-array content value (defensive against malformed payloads)" do
      response = {"content" => nil}

      expect(described_class.call(response)).to be(response)
    end

    it "tolerates symbol-keyed content and rewrites the same key (no mixed string/symbol shape)" do
      response = {content: [
        {type: "tool_use", id: "p1", name: "from_phantom", input: {}}
      ]}

      filtered = described_class.call(response)

      expect(filtered).to eq(content: [])
      expect(filtered.key?("content")).to be(false)
    end

    it "drops a tool_use whose name is exactly the bare prefix" do
      response = {"content" => [
        {"type" => "tool_use", "id" => "p1", "name" => "from_", "input" => {}}
      ]}

      expect(described_class.call(response)["content"]).to eq([])
    end

    it "ignores blocks that aren't hashes" do
      response = {"content" => ["not a hash", {"type" => "text", "text" => "real"}]}

      expect(described_class.call(response)).to be(response)
    end

    it "ignores tool_use blocks with a non-string name" do
      response = {"content" => [
        {"type" => "tool_use", "id" => "x", "name" => nil, "input" => {}}
      ]}

      expect(described_class.call(response)).to be(response)
    end
  end
end
