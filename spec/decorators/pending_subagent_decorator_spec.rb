# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingSubagentDecorator, type: :decorator do
  subject(:decorator) { pm.decorate }

  let(:session) { create(:session) }
  let(:pm) do
    build(:pending_message, :subagent,
      session: session,
      source_name: "scout",
      content: "found three matching files\nfile_a.rb\nfile_b.rb\nfile_c.rb")
  end

  describe "#render_basic" do
    it "is hidden in basic so it matches the promoted phantom pair's basic-mode visibility" do
      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#render_verbose" do
    it "returns dimmed sub-agent payload with the source nickname and 3-line cap" do
      expect(decorator.render_verbose).to eq(
        role: :pending_subagent,
        source: "scout",
        content: "found three matching files\nfile_a.rb\nfile_b.rb\n...",
        status: "pending"
      )
    end
  end

  describe "#render_debug" do
    it "returns the full untruncated content" do
      expect(decorator.render_debug[:content]).to include("file_c.rb")
    end
  end
end
