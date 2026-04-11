# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserMessageDecorator, type: :decorator do
  subject(:decorator) { message.decorate }

  describe "#render_basic" do
    let(:message) { build_stubbed(:message, :user_message, payload: {"content" => "hello world"}) }

    it "returns structured hash with user role and content" do
      expect(decorator.render_basic).to eq({role: :user, content: "hello world"})
    end

    context "with multiline content" do
      let(:message) { build_stubbed(:message, :user_message, payload: {"content" => "line 1\nline 2"}) }

      it "preserves the newlines" do
        expect(decorator.render_basic).to eq({role: :user, content: "line 1\nline 2"})
      end
    end
  end

  describe "#render_verbose" do
    let(:ts) { 1_709_312_325_000_000_000 }
    let(:message) { build_stubbed(:message, :user_message, payload: {"content" => "hello"}, timestamp: ts) }

    it "includes nanosecond timestamp" do
      expect(decorator.render_verbose).to eq({role: :user, content: "hello", timestamp: ts})
    end

    context "with multiline content" do
      let(:message) { build_stubbed(:message, :user_message, payload: {"content" => "line 1\nline 2"}, timestamp: ts) }

      it "preserves the newlines" do
        expect(decorator.render_verbose).to eq({role: :user, content: "line 1\nline 2", timestamp: ts})
      end
    end
  end

  describe "#render_debug" do
    let(:ts) { 1_709_312_325_000_000_000 }
    let(:message) { build_stubbed(:message, :user_message, payload: {"content" => "hello"}, timestamp: ts, token_count: 42) }

    it "includes stored token count alongside verbose data" do
      expect(decorator.render_debug).to eq({role: :user, content: "hello", timestamp: ts, tokens: 42})
    end
  end
end
