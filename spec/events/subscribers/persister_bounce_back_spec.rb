# frozen_string_literal: true

require "rails_helper"

RSpec.describe Events::Subscribers::Persister, "bounce back" do
  subject(:persister) { described_class.new }

  let(:session) { Session.create! }

  it "skips all user messages (callers handle persistence)" do
    event = {
      payload: {type: "user_message", content: "hello", session_id: session.id, timestamp: 1}
    }

    expect { persister.emit(event) }.not_to change(Message, :count)
  end

  it "still persists agent messages normally" do
    event = {
      payload: {type: "agent_message", content: "hi there", session_id: session.id, timestamp: 1}
    }

    expect { persister.emit(event) }.to change(Message, :count).by(1)
  end

  it "skips transient event types like bounce_back" do
    event = {
      payload: {type: "bounce_back", content: "hello", error: "err", session_id: session.id}
    }

    expect { persister.emit(event) }.not_to change(Message, :count)
  end
end
