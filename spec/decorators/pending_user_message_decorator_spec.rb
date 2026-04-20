# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingUserMessageDecorator, type: :decorator do
  subject(:decorator) { pm.decorate }

  let(:session) { create(:session) }
  let(:pm) { build(:pending_message, session: session, content: "write the ticket") }

  describe "#render_basic" do
    it "returns dimmed user payload" do
      expect(decorator.render_basic).to eq(role: :user, content: "write the ticket", status: "pending")
    end
  end

  describe "#render_verbose" do
    it "delegates to render_basic" do
      expect(decorator.render_verbose).to eq(decorator.render_basic)
    end
  end

  describe "#render_debug" do
    it "delegates to render_basic" do
      expect(decorator.render_debug).to eq(decorator.render_basic)
    end
  end
end
