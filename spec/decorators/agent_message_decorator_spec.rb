# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentMessageDecorator do
  subject(:decorator) { described_class.new(event_data) }

  let(:event_data) { {"type" => "agent_message", "content" => "hi there"} }

  describe "#render_basic" do
    it "returns content prefixed with 'Anima: '" do
      expect(decorator.render_basic).to eq(["Anima: hi there"])
    end

    it "splits multiline content into separate lines" do
      event_data["content"] = "first\nsecond"
      expect(decorator.render_basic).to eq(["Anima: first", "second"])
    end

    it "handles nil content gracefully" do
      event_data["content"] = nil
      expect(decorator.render_basic).to eq(["Anima: "])
    end

    it "handles empty content" do
      event_data["content"] = ""
      expect(decorator.render_basic).to eq(["Anima: "])
    end
  end

  describe "#label" do
    it "returns 'Anima'" do
      expect(decorator.label).to eq("Anima")
    end
  end

  describe "#role" do
    it "returns :assistant" do
      expect(decorator.role).to eq(:assistant)
    end
  end
end
