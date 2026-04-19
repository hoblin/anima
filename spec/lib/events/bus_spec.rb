# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Bus do
  let(:subscriber) { double("Subscriber", emit: nil) }

  after { described_class.unsubscribe(subscriber) }

  describe ".emit" do
    it "notifies subscribers with the event payload" do
      described_class.subscribe(subscriber)
      event = Events::UserMessage.new(content: "hello")

      described_class.emit(event)

      expect(subscriber).to have_received(:emit).with(
        hash_including(
          name: "anima.user_message",
          payload: hash_including(type: "user_message", content: "hello")
        )
      )
    end

    it "uses the event's event_name as notification name" do
      described_class.subscribe(subscriber)
      event = Events::SystemMessage.new(content: "response")

      described_class.emit(event)

      expect(subscriber).to have_received(:emit).with(
        hash_including(name: "anima.system_message")
      )
    end
  end

  describe ".subscribe / .unsubscribe" do
    it "registers a subscriber that receives events" do
      described_class.subscribe(subscriber)
      described_class.emit(Events::SystemMessage.new(content: "test"))

      expect(subscriber).to have_received(:emit).once
    end

    it "unsubscribes so events are no longer received" do
      described_class.subscribe(subscriber)
      described_class.unsubscribe(subscriber)
      described_class.emit(Events::SystemMessage.new(content: "test"))

      expect(subscriber).not_to have_received(:emit)
    end
  end
end
