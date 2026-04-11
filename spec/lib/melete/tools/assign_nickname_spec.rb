# frozen_string_literal: true

require "rails_helper"

RSpec.describe Melete::Tools::AssignNickname do
  describe ".tool_name" do
    it { expect(described_class.tool_name).to eq("assign_nickname") }
  end

  describe ".schema" do
    it "returns a valid Anthropic tool schema" do
      schema = described_class.schema

      expect(schema[:name]).to eq("assign_nickname")
      expect(schema[:description]).to be_present
      expect(schema[:input_schema][:required]).to eq(%w[nickname])
      expect(schema[:input_schema][:properties]).to have_key(:nickname)
    end
  end

  describe "#execute" do
    let(:parent) { Session.create! }
    let(:child) { Session.create!(parent_session: parent, prompt: "sub-agent") }
    let(:tool) { described_class.new(main_session: child) }

    it "assigns the nickname to the session" do
      result = tool.execute({"nickname" => "loop-sleuth"})

      expect(result).to eq("Nickname set to loop-sleuth")
      expect(child.reload.name).to eq("loop-sleuth")
    end

    it "downcases the nickname" do
      tool.execute({"nickname" => "Loop-Sleuth"})

      expect(child.reload.name).to eq("loop-sleuth")
    end

    it "strips whitespace" do
      tool.execute({"nickname" => "  api-scout  "})

      expect(child.reload.name).to eq("api-scout")
    end

    it "broadcasts name update via ActionCable" do
      expect {
        tool.execute({"nickname" => "test-fixer"})
      }.to have_broadcasted_to("session_#{child.id}")
        .with(a_hash_including(
          "action" => "session_name_updated",
          "name" => "test-fixer"
        ))
    end

    context "validation" do
      it "returns error when nickname is blank" do
        result = tool.execute({"nickname" => ""})

        expect(result).to eq({error: "Nickname cannot be blank"})
        expect(child.reload.name).to be_nil
      end

      it "returns error when nickname is nil" do
        result = tool.execute({"nickname" => nil})

        expect(result).to eq({error: "Nickname cannot be blank"})
      end

      it "returns error for invalid format (spaces)" do
        result = tool.execute({"nickname" => "loop sleuth"})

        expect(result).to include(error: a_string_matching(/Invalid format/))
      end

      it "returns error for invalid format (uppercase only)" do
        result = tool.execute({"nickname" => "LOUD"})

        # Input is downcased, so "LOUD" → "loud" which is valid
        expect(result).to eq("Nickname set to loud")
      end

      it "returns error for invalid format (special characters)" do
        result = tool.execute({"nickname" => "loop@sleuth!"})

        expect(result).to include(error: a_string_matching(/Invalid format/))
      end

      it "returns error for nickname starting with hyphen" do
        result = tool.execute({"nickname" => "-scout"})

        expect(result).to include(error: a_string_matching(/Invalid format/))
      end

      it "returns error when nickname exceeds max length" do
        long_name = "a" * 31
        result = tool.execute({"nickname" => long_name})

        expect(result).to include(error: a_string_matching(/too long/))
      end

      it "accepts single-word nicknames" do
        result = tool.execute({"nickname" => "scout"})

        expect(result).to eq("Nickname set to scout")
      end

      it "accepts three-word hyphenated nicknames" do
        result = tool.execute({"nickname" => "fast-code-reader"})

        expect(result).to eq("Nickname set to fast-code-reader")
      end
    end

    context "uniqueness among siblings" do
      it "returns error when nickname is taken by a sibling" do
        Session.create!(parent_session: parent, prompt: "sibling", name: "loop-sleuth")

        result = tool.execute({"nickname" => "loop-sleuth"})

        expect(result).to include(error: a_string_matching(/already taken/))
        expect(child.reload.name).to be_nil
      end

      it "allows a nickname not used by any sibling" do
        Session.create!(parent_session: parent, prompt: "sibling", name: "other-name")

        result = tool.execute({"nickname" => "loop-sleuth"})

        expect(result).to eq("Nickname set to loop-sleuth")
      end

      it "does not conflict with own name" do
        child.update!(name: "loop-sleuth")

        result = tool.execute({"nickname" => "loop-sleuth"})

        expect(result).to eq("Nickname set to loop-sleuth")
      end

      it "does not conflict with children of other parents" do
        other_parent = Session.create!
        Session.create!(parent_session: other_parent, prompt: "unrelated", name: "loop-sleuth")

        result = tool.execute({"nickname" => "loop-sleuth"})

        expect(result).to eq("Nickname set to loop-sleuth")
      end
    end

    it "accepts context kwargs without error" do
      tool = described_class.new(main_session: child, extra_stuff: "ignored")
      result = tool.execute({"nickname" => "scout"})

      expect(result).to eq("Nickname set to scout")
    end
  end
end
