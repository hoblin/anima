# frozen_string_literal: true

require "rails_helper"

RSpec.describe PendingToolResponseDecorator, type: :decorator do
  subject(:decorator) { pm.decorate }

  let(:session) { create(:session) }

  describe "#render_basic" do
    let(:pm) { build(:pending_message, :tool_response, session: session) }

    it "returns nil to mirror ToolResponseDecorator's basic-mode hide" do
      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#render_verbose" do
    let(:pm) do
      build(:pending_message, :tool_response,
        session: session,
        source_name: "bash",
        tool_use_id: "toolu_xyz",
        success: true,
        content: "line1\nline2\nline3\nline4")
    end

    it "returns dimmed tool_response payload truncated to 3 lines" do
      expect(decorator.render_verbose).to eq(
        role: :tool_response,
        tool: "bash",
        content: "line1\nline2\nline3\n...",
        success: true,
        tool_use_id: "toolu_xyz",
        status: "pending"
      )
    end

    context "with a failed response" do
      let(:pm) do
        build(:pending_message, :tool_response,
          session: session,
          source_name: "bash",
          tool_use_id: "toolu_fail",
          success: false,
          content: "command not found")
      end

      it "carries success: false" do
        expect(decorator.render_verbose[:success]).to be false
      end
    end
  end

  describe "#render_debug" do
    let(:pm) do
      build(:pending_message, :tool_response,
        session: session,
        source_name: "bash",
        tool_use_id: "toolu_xyz",
        success: true,
        content: "line1\nline2\nline3\nline4")
    end

    it "returns the full untruncated payload" do
      result = decorator.render_debug
      expect(result[:content]).to eq("line1\nline2\nline3\nline4")
      expect(result[:tool_use_id]).to eq("toolu_xyz")
      expect(result[:status]).to eq("pending")
    end
  end
end
