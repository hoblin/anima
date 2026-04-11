# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentMessageDecorator, type: :decorator do
  let(:session) { Session.create! }

  describe "#render_basic" do
    it "returns structured hash with assistant role and content" do
      event = session.messages.create!(message_type: "agent_message", payload: {"content" => "I can help"}, timestamp: 1)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to eq({role: :assistant, content: "I can help"})
    end

    it "handles multiline content" do
      event = session.messages.create!(message_type: "agent_message", payload: {"content" => "line 1\nline 2"}, timestamp: 1)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_basic).to eq({role: :assistant, content: "line 1\nline 2"})
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(type: "agent_message", content: "from hash")

      expect(decorator.render_basic).to eq({role: :assistant, content: "from hash"})
    end
  end

  describe "#render_verbose" do
    it "includes nanosecond timestamp" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(message_type: "agent_message", payload: {"content" => "I can help"}, timestamp: ts)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({role: :assistant, content: "I can help", timestamp: ts})
    end

    it "handles multiline content" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(message_type: "agent_message", payload: {"content" => "line 1\nline 2"}, timestamp: ts)
      decorator = MessageDecorator.for(event)

      expect(decorator.render_verbose).to eq({role: :assistant, content: "line 1\nline 2", timestamp: ts})
    end

    it "includes nil timestamp when missing" do
      decorator = MessageDecorator.for(type: "agent_message", content: "no timestamp")

      expect(decorator.render_verbose).to eq({role: :assistant, content: "no timestamp", timestamp: nil})
    end
  end

  describe "#render_debug" do
    it "includes stored token count" do
      ts = 1_709_312_325_000_000_000
      event = session.messages.create!(
        message_type: "agent_message", payload: {"content" => "I can help"}, timestamp: ts, token_count: 156
      )
      decorator = MessageDecorator.for(event)

      expect(decorator.render_debug).to eq({
        role: :assistant, content: "I can help", timestamp: ts, tokens: 156
      })
    end

    it "works with hash payloads" do
      decorator = MessageDecorator.for(type: "agent_message", content: "from hash")
      result = decorator.render_debug

      expect(result[:role]).to eq(:assistant)
      expect(result[:tokens]).to be_a(Integer)
    end
  end
end
