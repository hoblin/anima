# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentMessageDecorator, type: :decorator do
  subject(:decorator) { message.decorate }

  describe "#render_basic" do
    let(:message) { build_stubbed(:message, :agent_message, payload: {"content" => "I can help"}) }

    it "returns structured hash with assistant role and content" do
      expect(decorator.render_basic).to eq({role: :assistant, content: "I can help"})
    end

    context "with multiline content" do
      let(:message) { build_stubbed(:message, :agent_message, payload: {"content" => "line 1\nline 2"}) }

      it "preserves the newlines" do
        expect(decorator.render_basic).to eq({role: :assistant, content: "line 1\nline 2"})
      end
    end
  end

  describe "#render_verbose" do
    let(:ts) { 1_709_312_325_000_000_000 }
    let(:message) { build_stubbed(:message, :agent_message, payload: {"content" => "I can help"}, timestamp: ts) }

    it "includes nanosecond timestamp" do
      expect(decorator.render_verbose).to eq({role: :assistant, content: "I can help", timestamp: ts})
    end

    context "with multiline content" do
      let(:message) { build_stubbed(:message, :agent_message, payload: {"content" => "line 1\nline 2"}, timestamp: ts) }

      it "preserves the newlines" do
        expect(decorator.render_verbose).to eq({role: :assistant, content: "line 1\nline 2", timestamp: ts})
      end
    end
  end

  describe "#render_debug" do
    let(:ts) { 1_709_312_325_000_000_000 }
    let(:message) { build_stubbed(:message, :agent_message, payload: {"content" => "I can help"}, timestamp: ts, token_count: 156) }

    it "includes stored token count alongside verbose data" do
      expect(decorator.render_debug).to eq({role: :assistant, content: "I can help", timestamp: ts, tokens: 156})
    end
  end
end
