# frozen_string_literal: true

require "rails_helper"

# Shared assertions for the three Melete-activation pending decorators —
# they share the visual treatment, only the kind label and source field
# differ.
RSpec.describe "Pending Melete activation decorators" do
  let(:session) { create(:session) }

  {
    PendingFromMeleteSkillDecorator => {trait: :from_melete_skill, kind: "skill", source_name: "gh-issue"},
    PendingFromMeleteWorkflowDecorator => {trait: :from_melete_workflow, kind: "workflow", source_name: "feature"},
    PendingFromMeleteGoalDecorator => {trait: :from_melete_goal, kind: "goal", source_name: "42"}
  }.each do |klass, meta|
    describe klass do
      let(:pm) do
        build(:pending_message, meta[:trait],
          session: session,
          source_name: meta[:source_name],
          content: "line1\nline2\nline3\nline4")
      end

      describe "#render_basic" do
        it "is hidden in basic — activations are background context" do
          expect(pm.decorate.render_basic).to be_nil
        end
      end

      describe "#render_verbose" do
        it "returns dimmed pending_melete payload with kind + source" do
          expect(pm.decorate.render_verbose).to eq(
            role: :pending_melete,
            kind: meta[:kind],
            source: meta[:source_name],
            content: "line1\nline2\nline3\n...",
            status: "pending"
          )
        end
      end

      describe "#render_debug" do
        it "returns the full untruncated content" do
          expect(pm.decorate.render_debug[:content]).to eq("line1\nline2\nline3\nline4")
        end
      end
    end
  end
end
