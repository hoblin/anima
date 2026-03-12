# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserMessageDecorator do
  subject(:decorator) { described_class.new(event_data) }

  let(:event_data) { {"type" => "user_message", "content" => "hello world"} }

  describe "#render_basic" do
    it "returns content prefixed with 'You: '" do
      expect(decorator.render_basic).to eq(["You: hello world"])
    end

    it "splits multiline content into separate lines" do
      event_data["content"] = "line one\nline two\nline three"
      expect(decorator.render_basic).to eq(["You: line one", "line two", "line three"])
    end

    it "handles nil content gracefully" do
      event_data["content"] = nil
      expect(decorator.render_basic).to eq(["You: "])
    end

    it "handles empty content" do
      event_data["content"] = ""
      expect(decorator.render_basic).to eq(["You: "])
    end

    it "preserves trailing newlines in content" do
      event_data["content"] = "hello\n"
      expect(decorator.render_basic).to eq(["You: hello", ""])
    end
  end

  describe "#label" do
    it "returns 'You'" do
      expect(decorator.label).to eq("You")
    end
  end

  describe "#role" do
    it "returns :user" do
      expect(decorator.role).to eq(:user)
    end
  end
end
