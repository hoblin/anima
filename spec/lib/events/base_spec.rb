# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Base do
  subject(:event) { described_class.new(content: "test content", session_id: "sess-1") }

  describe "#initialize" do
    it "stores content" do
      expect(event.content).to eq("test content")
    end

    it "stores session_id" do
      expect(event.session_id).to eq("sess-1")
    end

    it "generates a nanosecond timestamp" do
      expect(event.timestamp).to be_a(Integer)
      expect(event.timestamp).to be > 0
    end

    it "defaults session_id to nil" do
      event = described_class.new(content: "test")
      expect(event.session_id).to be_nil
    end
  end

  describe "#type" do
    it "raises NotImplementedError" do
      expect { event.type }.to raise_error(NotImplementedError, /must implement #type/)
    end
  end

  describe "#event_name" do
    it "uses Bus::NAMESPACE as prefix" do
      concrete = Events::UserMessage.new(content: "test")
      expect(concrete.event_name).to start_with("#{Events::Bus::NAMESPACE}.")
    end
  end

  describe "#to_h" do
    it "raises NotImplementedError because type is abstract" do
      expect { event.to_h }.to raise_error(NotImplementedError)
    end
  end
end
