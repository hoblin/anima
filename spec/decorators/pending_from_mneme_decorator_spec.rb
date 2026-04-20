# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingFromMnemeDecorator, type: :decorator do
  subject(:decorator) { pm.decorate }

  let(:session) { create(:session) }
  let(:pm) { build(:pending_message, :from_mneme, session: session, content: "long\nrecalled\nmemory\nbody") }

  describe "#render_basic" do
    it "is hidden in basic — Mneme recalls are background context" do
      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#render_verbose" do
    it "returns the dimmed pending_mneme payload truncated to 3 lines" do
      expect(decorator.render_verbose).to eq(
        role: :pending_mneme,
        content: "long\nrecalled\nmemory\n...",
        status: "pending"
      )
    end
  end

  describe "#render_debug" do
    it "returns the full untruncated content" do
      expect(decorator.render_debug[:content]).to eq("long\nrecalled\nmemory\nbody")
    end
  end
end
