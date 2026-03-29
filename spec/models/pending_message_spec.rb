# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingMessage, type: :model do
  let(:session) { Session.create! }

  describe "validations" do
    it "requires content" do
      pm = PendingMessage.new(session: session, content: nil)
      expect(pm).not_to be_valid
    end

    it "requires a session" do
      pm = PendingMessage.new(content: "hello")
      expect(pm).not_to be_valid
    end

    it "is valid with session and content" do
      pm = PendingMessage.new(session: session, content: "hello")
      expect(pm).to be_valid
    end
  end

  describe "broadcasts" do
    it "broadcasts pending_message_created on create" do
      expect {
        session.pending_messages.create!(content: "waiting")
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_created", "content" => "waiting"))
    end

    it "broadcasts pending_message_removed on destroy" do
      pm = session.pending_messages.create!(content: "waiting")

      expect {
        pm.destroy!
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including("action" => "pending_message_removed", "pending_message_id" => pm.id))
    end
  end

  describe "dependent destroy" do
    it "is destroyed when session is destroyed" do
      session.pending_messages.create!(content: "orphan")

      expect { session.destroy! }.to change(PendingMessage, :count).by(-1)
    end
  end
end
