# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::RelevanceGate do
  let(:client) { instance_double(LLM::Client) }
  let(:fake_sub_goal) { Struct.new(:description, :completed?) }
  let(:fake_goal) { Struct.new(:description, :sub_goals) }

  def result(id, snippet)
    Mneme::Search::Result.new(
      message_id: id,
      session_id: 1,
      snippet: snippet,
      rank: -1.0,
      message_type: "human"
    )
  end

  def goal(description, sub_goals: [])
    fake_goal.new(description, sub_goals)
  end

  def sub_goal(description, completed: false)
    fake_sub_goal.new(description, completed)
  end

  describe "#call" do
    it "returns an empty array and skips the LLM call when given no candidates" do
      expect(client).not_to receive(:chat_with_tools)

      kept = described_class.new(
        goals: [goal("Fix auth")],
        candidates: [],
        client: client
      ).call

      expect(kept).to eq([])
    end

    it "keeps only candidates whose ids the model returns under `keep`" do
      keep = result(42, "OAuth refresh token 401 fix")
      drop = result(99, "CSS pixel nudge")

      allow(client).to receive(:chat_with_tools).and_return(
        text: %({"keep": [42]})
      )

      kept = described_class.new(
        goals: [goal("Fix OAuth token refresh")],
        candidates: [keep, drop],
        client: client
      ).call

      expect(kept.map(&:message_id)).to eq([42])
    end

    it "returns nothing when the model keeps nothing" do
      allow(client).to receive(:chat_with_tools).and_return(text: %({"keep": []}))

      kept = described_class.new(
        goals: [goal("Anything")],
        candidates: [result(1, "whatever")],
        client: client
      ).call

      expect(kept).to eq([])
    end

    it "tolerates the model wrapping JSON in prose or a fence" do
      allow(client).to receive(:chat_with_tools).and_return(
        text: "Sure — here's my answer: ```json\n{\"keep\": [7]}\n```"
      )

      kept = described_class.new(
        goals: [goal("Anything")],
        candidates: [result(7, "kept"), result(8, "dropped")],
        client: client
      ).call

      expect(kept.map(&:message_id)).to eq([7])
    end

    it "raises when the model produces no JSON object" do
      allow(client).to receive(:chat_with_tools).and_return(text: "no idea")

      expect {
        described_class.new(
          goals: [goal("Anything")],
          candidates: [result(1, "whatever")],
          client: client
        ).call
      }.to raise_error(ArgumentError, /no JSON object/)
    end

    it "sends the rendered goals and candidate snippets as the user message" do
      captured_messages = nil
      allow(client).to receive(:chat_with_tools) { |messages, **|
        captured_messages = messages
        {text: %({"keep": []})}
      }

      goals = [goal("Fix OAuth", sub_goals: [
        sub_goal("Refresh tokens"),
        sub_goal("Already done", completed: true)
      ])]

      described_class.new(
        goals: goals,
        candidates: [result(42, "OAuth fix snippet")],
        client: client
      ).call

      content = captured_messages.first[:content]
      expect(content).to include("- Fix OAuth")
      expect(content).to include("• Refresh tokens")
      expect(content).not_to include("Already done")
      expect(content).to include("message 42: OAuth fix snippet")
    end
  end
end
