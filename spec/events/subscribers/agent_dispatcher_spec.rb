# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::AgentDispatcher do
  subject(:dispatcher) { described_class.new }

  describe "#emit" do
    it "schedules AgentRequestJob for non-pending user messages" do
      event = {
        payload: {type: "user_message", content: "hello", session_id: 1, timestamp: 1}
      }

      expect { dispatcher.emit(event) }
        .to have_enqueued_job(AgentRequestJob)
        .with(1, content: "hello")
    end

    it "skips pending user messages" do
      event = {
        payload: {type: "user_message", content: "hello", session_id: 1, status: Event::PENDING_STATUS}
      }

      expect { dispatcher.emit(event) }
        .not_to have_enqueued_job(AgentRequestJob)
    end

    it "skips non-user_message event types" do
      event = {
        payload: {type: "agent_message", content: "hi", session_id: 1}
      }

      expect { dispatcher.emit(event) }
        .not_to have_enqueued_job(AgentRequestJob)
    end

    it "skips events without session_id" do
      event = {
        payload: {type: "user_message", content: "hello", session_id: nil}
      }

      expect { dispatcher.emit(event) }
        .not_to have_enqueued_job(AgentRequestJob)
    end
  end
end
