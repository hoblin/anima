# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolDecorator do
  describe ".call" do
    it "passes error hashes through undecorated" do
      error = {error: "something broke"}
      expect(described_class.call("web_get", error)).to eq(error)
    end

    it "dispatches to the registered decorator for web_get" do
      result = {body: '{"a":1}', content_type: "application/json"}
      decorated = described_class.call("web_get", result)

      expect(decorated).to be_a(String)
      expect(decorated).to include("[Converted: JSON → TOON]")
    end

    it "passes through results for tools without a decorator" do
      result = "some output"
      expect(described_class.call("bash", result)).to eq("some output")
    end

    it "passes through string results for unregistered tools" do
      result = "hello"
      expect(described_class.call("unknown_tool", result)).to eq("hello")
    end
  end
end
