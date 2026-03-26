# frozen_string_literal: true

require "rails_helper"

RSpec.describe PassiveRecallJob do
  let(:session) { Session.create! }

  def create_message(sess, type:, content:)
    sess.messages.create!(
      message_type: type,
      payload: {"content" => content},
      timestamp: Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond)
    )
  end

  it "discards on RecordNotFound" do
    expect { described_class.perform_now(-1) }.not_to raise_error
  end

  it "stores recalled message IDs on the session" do
    other_session = Session.create!
    event = create_message(other_session, type: "user_message",
      content: "The authentication module is broken")

    session.goals.create!(description: "Fix the authentication module")

    described_class.perform_now(session.id)

    expect(session.reload.recalled_message_ids).to include(event.id)
  end

  it "clears recalled IDs when no results match" do
    session.update_column(:recalled_message_ids, [999])

    described_class.perform_now(session.id)

    expect(session.reload.recalled_message_ids).to eq([])
  end

  it "leaves recalled IDs empty when no goals exist" do
    described_class.perform_now(session.id)

    expect(session.reload.recalled_message_ids).to eq([])
  end
end
