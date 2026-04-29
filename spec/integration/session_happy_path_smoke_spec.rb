# frozen_string_literal: true

require "rails_helper"

# End-to-end smoke test for the happy path of a main session: a user
# message enters through the same entry point the client uses, flows
# through the full event-driven drain pipeline (Melete → (Mneme) → Drain),
# and produces an assistant response.
#
# The prompt is deliberately open-ended — we're testing an agent, not a
# function. Whatever tools Ani chooses, whatever path she takes, as long
# as she responds and the session winds back down to idle, the pipeline
# is alive. When the prompt or any tool schema changes, re-record via:
#
#   bin/with-llms bundle exec rspec spec/integration/session_happy_path_smoke_spec.rb
#
# Match on method + URI (not body) because the cassette covers multiple
# LLM calls whose bodies reference message IDs and timestamps that drift
# across recordings.
RSpec.describe "Session happy path smoke", vcr: {match_requests_on: [:method, :uri]} do
  let(:persister) { Events::Subscribers::Persister.new }
  let(:session) { Session.create! }

  before do
    # The Persister subscribes globally in non-test environments; the
    # smoke wires it in manually so agent_message / tool_call events
    # produced by the pipeline become real Message rows.
    Events::Bus.subscribe(persister)
  end

  after do
    Events::Bus.unsubscribe(persister)
    ShellSession.release(session.id)
  end

  it "answers a real question by driving the full drain pipeline" do
    perform_enqueued_jobs do
      session.enqueue_user_message("What's the most recent open issue on this repo?")
    end

    session.reload

    final_answer = session.messages.where(message_type: "agent_message").last&.payload&.dig("content")
    expect(final_answer).to include("473")
  end
end
