# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RequestFeature do
  subject(:tool) { described_class.new }

  describe ".tool_name" do
    it "returns request_feature" do
      expect(described_class.tool_name).to eq("request_feature")
    end
  end

  describe ".description" do
    it "returns a motivational, non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".input_schema" do
    it "defines title and description as required string properties" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:title][:type]).to eq("string")
      expect(schema[:properties][:description][:type]).to eq("string")
      expect(schema[:required]).to contain_exactly("title", "description")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "request_feature", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    let(:issue_url) { "https://github.com/hoblin/anima/issues/999\n" }

    before do
      allow(Anima::Settings).to receive(:github_repo).and_return("hoblin/anima")
      allow(Anima::Settings).to receive(:github_label).and_return("anima-wants")
    end

    context "with valid input" do
      before do
        allow(Open3).to receive(:capture3)
          .with("gh", "issue", "create", "--repo", "hoblin/anima",
            "--label", "anima-wants", "--title", "Need a zoom tool",
            "--body", "I tried to inspect a nested data structure but lack a zoom tool.")
          .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])
      end

      it "returns the issue URL" do
        result = tool.execute(
          "title" => "Need a zoom tool",
          "description" => "I tried to inspect a nested data structure but lack a zoom tool."
        )
        expect(result).to eq("https://github.com/hoblin/anima/issues/999")
      end
    end

    context "when gh produces both stdout and stderr on success" do
      before do
        allow(Open3).to receive(:capture3)
          .and_return(["https://github.com/hoblin/anima/issues/42\n",
            "Creating issue in hoblin/anima\n",
            instance_double(Process::Status, exitstatus: 0)])
      end

      it "returns both stdout and stderr" do
        result = tool.execute("title" => "Feature", "description" => "Details")
        expect(result).to include("https://github.com/hoblin/anima/issues/42")
        expect(result).to include("Creating issue in hoblin/anima")
      end
    end

    context "when gh reports an error" do
      before do
        allow(Open3).to receive(:capture3)
          .and_return(["", "gh: Not logged in. Run `gh auth login`.\n",
            instance_double(Process::Status, exitstatus: 1)])
      end

      it "returns stderr and exit code" do
        result = tool.execute("title" => "Something", "description" => "Details")
        expect(result).to include("gh: Not logged in")
        expect(result).to include("exit_code: 1")
      end
    end

    context "with blank title" do
      it "returns an error" do
        result = tool.execute("title" => "  ", "description" => "details")
        expect(result).to eq({error: "Title cannot be blank"})
      end
    end

    context "with blank description" do
      it "returns an error" do
        result = tool.execute("title" => "Feature", "description" => "")
        expect(result).to eq({error: "Description cannot be blank"})
      end
    end

    context "with nil title" do
      it "returns an error" do
        result = tool.execute("description" => "details")
        expect(result).to eq({error: "Title cannot be blank"})
      end
    end

    context "with nil description" do
      it "returns an error" do
        result = tool.execute("title" => "Feature")
        expect(result).to eq({error: "Description cannot be blank"})
      end
    end

    context "repo resolution" do
      context "when config.toml has [github] repo" do
        before do
          allow(Anima::Settings).to receive(:github_repo).and_return("other/repo")
          allow(Open3).to receive(:capture3)
            .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])
        end

        it "uses the configured repo" do
          tool.execute("title" => "Feature", "description" => "Details")
          expect(Open3).to have_received(:capture3)
            .with("gh", "issue", "create", "--repo", "other/repo",
              "--label", "anima-wants", "--title", "Feature", "--body", "Details")
        end
      end

      context "when config.toml repo is an empty string" do
        before do
          allow(Anima::Settings).to receive(:github_repo).and_return("  ")
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_return(["https://github.com/hoblin/anima.git\n", instance_double(Process::Status, exitstatus: 0, success?: true)])
          allow(Open3).to receive(:capture3)
            .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])
        end

        it "falls back to git remote origin" do
          tool.execute("title" => "Feature", "description" => "Details")
          expect(Open3).to have_received(:capture3)
            .with("gh", "issue", "create", "--repo", "hoblin/anima",
              "--label", "anima-wants", "--title", "Feature", "--body", "Details")
        end
      end

      context "when config.toml setting is missing" do
        before do
          allow(Anima::Settings).to receive(:github_repo)
            .and_raise(Anima::Settings::MissingSettingError, "[github] repo is not set")
        end

        it "falls back to git remote origin (HTTPS)" do
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_return(["https://github.com/hoblin/anima.git\n", instance_double(Process::Status, exitstatus: 0, success?: true)])
          allow(Open3).to receive(:capture3)
            .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])

          tool.execute("title" => "Feature", "description" => "Details")
          expect(Open3).to have_received(:capture3)
            .with("gh", "issue", "create", "--repo", "hoblin/anima",
              "--label", "anima-wants", "--title", "Feature", "--body", "Details")
        end

        it "falls back to git remote origin (SSH)" do
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_return(["git@github.com:hoblin/anima.git\n", instance_double(Process::Status, exitstatus: 0, success?: true)])
          allow(Open3).to receive(:capture3)
            .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])

          tool.execute("title" => "Feature", "description" => "Details")
          expect(Open3).to have_received(:capture3)
            .with("gh", "issue", "create", "--repo", "hoblin/anima",
              "--label", "anima-wants", "--title", "Feature", "--body", "Details")
        end

        it "falls back to git remote origin (HTTPS without .git)" do
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_return(["https://github.com/hoblin/anima\n", instance_double(Process::Status, exitstatus: 0, success?: true)])
          allow(Open3).to receive(:capture3)
            .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])

          tool.execute("title" => "Feature", "description" => "Details")
          expect(Open3).to have_received(:capture3)
            .with("gh", "issue", "create", "--repo", "hoblin/anima",
              "--label", "anima-wants", "--title", "Feature", "--body", "Details")
        end

        it "returns error when remote URL is not GitHub" do
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_return(["https://gitlab.com/user/repo.git\n", instance_double(Process::Status, exitstatus: 0, success?: true)])

          result = tool.execute("title" => "Feature", "description" => "Details")
          expect(result).to be_a(Hash)
          expect(result[:error]).to include("Cannot determine repository")
        end

        it "returns error when git remote command fails" do
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_return(["", instance_double(Process::Status, exitstatus: 1, success?: false)])

          result = tool.execute("title" => "Feature", "description" => "Details")
          expect(result).to be_a(Hash)
          expect(result[:error]).to include("Cannot determine repository")
        end

        it "returns error when git is not available" do
          allow(Open3).to receive(:capture2)
            .with("git", "remote", "get-url", "origin", err: File::NULL)
            .and_raise(Errno::ENOENT)

          result = tool.execute("title" => "Feature", "description" => "Details")
          expect(result).to be_a(Hash)
          expect(result[:error]).to include("Cannot determine repository")
        end
      end
    end

    context "label from settings" do
      before do
        allow(Anima::Settings).to receive(:github_label).and_return("custom-label")
        allow(Open3).to receive(:capture3)
          .and_return([issue_url, "", instance_double(Process::Status, exitstatus: 0)])
      end

      it "uses the configured label" do
        tool.execute("title" => "Feature", "description" => "Details")
        expect(Open3).to have_received(:capture3)
          .with("gh", "issue", "create", "--repo", "hoblin/anima",
            "--label", "custom-label", "--title", "Feature", "--body", "Details")
      end
    end
  end
end
