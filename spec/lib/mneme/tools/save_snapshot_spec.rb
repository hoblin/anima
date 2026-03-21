# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mneme::Tools::SaveSnapshot do
  let(:session) { Session.create! }

  before do
    allow(Anima::Settings).to receive(:mneme_max_tokens).and_return(2048)
  end

  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("save_snapshot") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("save_snapshot")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to include("text")
    end
  end

  describe "#execute" do
    let(:tool) { described_class.new(main_session: session, from_event_id: 1, to_event_id: 50) }

    it "creates a snapshot record" do
      expect {
        tool.execute("text" => "The user discussed authentication flow.")
      }.to change(Snapshot, :count).by(1)
    end

    it "saves the snapshot with correct attributes" do
      tool.execute("text" => "The user discussed authentication flow.")

      snapshot = Snapshot.last
      expect(snapshot.session).to eq(session)
      expect(snapshot.text).to eq("The user discussed authentication flow.")
      expect(snapshot.from_event_id).to eq(1)
      expect(snapshot.to_event_id).to eq(50)
      expect(snapshot.level).to eq(1)
      expect(snapshot.token_count).to be > 0
    end

    it "returns a confirmation string with event range" do
      result = tool.execute("text" => "Summary of events.")

      expect(result).to include("Snapshot saved")
      expect(result).to include("events 1..50")
    end

    it "returns an error for blank text" do
      result = tool.execute("text" => "  ")

      expect(result).to eq({error: "Summary text cannot be blank"})
    end

    it "returns an error for nil text" do
      result = tool.execute("text" => nil)

      expect(result).to eq({error: "Summary text cannot be blank"})
    end

    it "estimates token count for the saved snapshot" do
      tool.execute("text" => "A" * 400)

      snapshot = Snapshot.last
      expect(snapshot.token_count).to eq(100)
    end
  end
end
