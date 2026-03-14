# frozen_string_literal: true

require "rails_helper"

RSpec.describe SubagentCompletedDecorator do
  let(:session) { Session.create! }
  let(:event) do
    session.events.create!(
      event_type: "subagent_completed",
      payload: {
        "content" => "The API uses cursor-based pagination.",
        "task" => "Research pagination API",
        "child_session_id" => 42,
        "expected_output" => "Summary of pagination"
      },
      timestamp: 1_000_000_000
    )
  end

  subject(:decorator) { EventDecorator.for(event) }

  it "resolves to SubagentCompletedDecorator" do
    expect(decorator).to be_a(described_class)
  end

  describe "#render_basic" do
    it "returns subagent role with content and task" do
      result = decorator.render_basic

      expect(result[:role]).to eq(:subagent)
      expect(result[:content]).to eq("The API uses cursor-based pagination.")
      expect(result[:task]).to eq("Research pagination API")
    end
  end

  describe "#render_verbose" do
    it "includes timestamp" do
      result = decorator.render_verbose

      expect(result[:role]).to eq(:subagent)
      expect(result[:content]).to eq("The API uses cursor-based pagination.")
      expect(result[:timestamp]).to eq(1_000_000_000)
    end
  end

  describe "#render_debug" do
    it "includes child_session_id and token info" do
      result = decorator.render_debug

      expect(result[:role]).to eq(:subagent)
      expect(result[:child_session_id]).to eq(42)
      expect(result).to have_key(:tokens)
      expect(result).to have_key(:estimated)
    end
  end

  describe "#render" do
    it "dispatches to the correct render method" do
      expect(decorator.render("basic")).to eq(decorator.render_basic)
      expect(decorator.render("verbose")).to eq(decorator.render_verbose)
      expect(decorator.render("debug")).to eq(decorator.render_debug)
    end
  end
end
