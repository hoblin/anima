# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolResponseDecorator do
  subject(:decorator) { described_class.new(event_data) }

  let(:event_data) do
    {
      "type" => "tool_response",
      "content" => "file1.txt\nfile2.txt",
      "tool_name" => "bash",
      "tool_use_id" => "toolu_123"
    }
  end

  describe "#render_basic" do
    it "returns nil (hidden in basic mode)" do
      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#label" do
    it "returns nil" do
      expect(decorator.label).to be_nil
    end
  end

  describe "#role" do
    it "returns nil" do
      expect(decorator.role).to be_nil
    end
  end
end
