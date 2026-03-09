# frozen_string_literal: true

require "rails_helper"

RSpec.describe SessionChannel, type: :channel do
  let(:session_id) { 42 }
  let(:stream_name) { "session_#{session_id}" }

  describe "#subscribed" do
    it "streams from the session-specific stream" do
      subscribe(session_id: session_id)

      expect(subscription).to be_confirmed
      expect(subscription).to have_stream_from(stream_name)
    end
  end

  describe "#receive" do
    it "broadcasts the received data to the session stream" do
      subscribe(session_id: session_id)
      data = {"type" => "user_message", "content" => "hello"}

      expect { perform(:receive, data) }
        .to have_broadcasted_to(stream_name).with(hash_including(data))
    end
  end
end
