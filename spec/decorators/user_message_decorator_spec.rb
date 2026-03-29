# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserMessageDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns structured hash with user role and content" do
      event = session.messages.create!(message_type: "user_message", payload: {"content" => "hello world"}, timestamp: 1)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to eq({role: :user, content: "hello world"})
    end

    it "handles multiline content" do
      event = session.messages.create!(message_type: "user_message", payload: {"content" => "line 1\nline 2"}, timestamp: 1)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to eq({role: :user, content: "line 1\nline 2"})
    end

    it "works with hash payloads (symbol keys)" do
      decorator = MessageDecorator.for(type: "user_message", content: "from hash")

      expect(decorator.render_basic).to eq({role: :user, content: "from hash"})
    end

    it "works with hash payloads (string keys)" do
      decorator = MessageDecorator.for("type" => "user_message", "content" => "from string hash")

      expect(decorator.render_basic).to eq({role: :user, content: "from string hash"})
    end
  end

  describe "#render_verbose" do
    it "includes nanosecond timestamp" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(message_type: "user_message", payload: {"content" => "hello"}, timestamp: ts)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({role: :user, content: "hello", timestamp: ts})
    end

    it "handles multiline content" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(message_type: "user_message", payload: {"content" => "line 1\nline 2"}, timestamp: ts)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({role: :user, content: "line 1\nline 2", timestamp: ts})
    end

    it "includes nil timestamp when missing" do
      decorator = MessageDecorator.for(type: "user_message", content: "no timestamp")

      expect(decorator.render_verbose).to eq({role: :user, content: "no timestamp", timestamp: nil})
    end
  end

  describe "#render_debug" do
    it "includes exact token count when available" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(
        message_type: "user_message", payload: {"content" => "hello"}, timestamp: ts, token_count: 42
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_debug).to eq({
        role: :user, content: "hello", timestamp: ts, tokens: 42, estimated: false
      })
    end

    it "includes estimated token count when not yet counted" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(
        message_type: "user_message", payload: {"content" => "hello"}, timestamp: ts
      )
      decorator = MessageDecorator.for(event)
      result = decorator.render_debug

      expect(result[:role]).to eq(:user)
      expect(result[:content]).to eq("hello")
      expect(result[:timestamp]).to eq(ts)
      expect(result[:tokens]).to be_positive
      expect(result[:estimated]).to be true
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(type: "user_message", content: "from hash")
      result = decorator.render_debug

      expect(result[:role]).to eq(:user)
      expect(result[:content]).to eq("from hash")
      expect(result[:tokens]).to be_positive
      expect(result[:estimated]).to be true
    end
  end
end
