# frozen_string_literal: true

require "rails_helper"

RSpec.describe AnalyticalBrain::Tools::RenameSession do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("rename_session") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("rename_session")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[emoji name])
      expect(schema[:input_schema][:properties]).to have_key(:emoji)
      expect(schema[:input_schema][:properties]).to have_key(:name)
    end
  end

  describe "#execute" do
    let(:session) { Session.create! }
    let(:tool) { described_class.new(main_session: session) }

    it "renames the session with emoji and name" do
      result = tool.execute({"emoji" => "🔧", "name" => "Fix login bug"})

      expect(result).to include("🔧 Fix login bug")
      expect(session.reload.name).to eq("🔧 Fix login bug")
    end

    it "broadcasts name update via ActionCable" do
      expect {
        tool.execute({"emoji" => "💎", "name" => "Ruby Basics"})
      }.to have_broadcasted_to("session_#{session.id}")
        .with(a_hash_including(
          "action" => "session_name_updated",
          "name" => "💎 Ruby Basics"
        ))
    end

    it "truncates names longer than 255 characters" do
      tool.execute({"emoji" => "🔧", "name" => "A" * 260})

      expect(session.reload.name.length).to be <= 255
    end

    it "returns error when emoji is blank" do
      result = tool.execute({"emoji" => "", "name" => "Test"})

      expect(result).to eq({error: "Emoji cannot be blank"})
      expect(session.reload.name).to be_nil
    end

    it "returns error when name is blank" do
      result = tool.execute({"emoji" => "🔧", "name" => ""})

      expect(result).to eq({error: "Name cannot be blank"})
      expect(session.reload.name).to be_nil
    end

    it "returns error when emoji is nil" do
      result = tool.execute({"emoji" => nil, "name" => "Test"})

      expect(result).to eq({error: "Emoji cannot be blank"})
    end

    it "strips whitespace from emoji and name" do
      tool.execute({"emoji" => "  🎉  ", "name" => "  Fun Chat  "})

      expect(session.reload.name).to eq("🎉 Fun Chat")
    end

    it "overwrites existing session names" do
      session.update!(name: "Old Name")

      tool.execute({"emoji" => "🆕", "name" => "New Topic"})

      expect(session.reload.name).to eq("🆕 New Topic")
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: session, extra_stuff: "ignored")
      result = tool.execute({"emoji" => "🔧", "name" => "Works"})

      expect(result).to include("🔧 Works")
    end
  end
end
