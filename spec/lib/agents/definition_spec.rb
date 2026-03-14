# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Definition do
  describe ".from_file" do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:agent_path) { File.join(tmp_dir, "test-agent.md") }

    after { FileUtils.remove_entry(tmp_dir) }

    context "with a valid definition file" do
      before do
        File.write(agent_path, <<~MD)
          ---
          name: test-agent
          description: A test agent for specs
          tools: read, bash, web_get
          model: claude-sonnet-4-5
          color: blue
          maxTurns: 10
          ---

          You are a test agent. Do test things.

          ## Guidelines
          - Be thorough
        MD
      end

      it "parses name from frontmatter" do
        definition = described_class.from_file(agent_path)
        expect(definition.name).to eq("test-agent")
      end

      it "parses description from frontmatter" do
        definition = described_class.from_file(agent_path)
        expect(definition.description).to eq("A test agent for specs")
      end

      it "parses comma-separated tools into a normalized array" do
        definition = described_class.from_file(agent_path)
        expect(definition.tools).to eq(%w[read bash web_get])
      end

      it "extracts the Markdown body as the system prompt" do
        definition = described_class.from_file(agent_path)
        expect(definition.prompt).to include("You are a test agent")
        expect(definition.prompt).to include("## Guidelines")
      end

      it "parses optional model field" do
        definition = described_class.from_file(agent_path)
        expect(definition.model).to eq("claude-sonnet-4-5")
      end

      it "parses optional color field" do
        definition = described_class.from_file(agent_path)
        expect(definition.color).to eq("blue")
      end

      it "parses optional maxTurns field" do
        definition = described_class.from_file(agent_path)
        expect(definition.max_turns).to eq(10)
      end

      it "records the source file path" do
        definition = described_class.from_file(agent_path)
        expect(definition.source_path).to eq(agent_path)
      end
    end

    context "with array-format tools" do
      before do
        File.write(agent_path, <<~MD)
          ---
          name: array-tools
          description: Agent with array tools
          tools:
            - read
            - bash
          ---

          System prompt here.
        MD
      end

      it "accepts YAML array syntax for tools" do
        definition = described_class.from_file(agent_path)
        expect(definition.tools).to eq(%w[read bash])
      end
    end

    context "with minimal frontmatter" do
      before do
        File.write(agent_path, <<~MD)
          ---
          name: minimal
          description: Minimal agent
          ---

          Just a prompt.
        MD
      end

      it "defaults tools to empty array when omitted" do
        definition = described_class.from_file(agent_path)
        expect(definition.tools).to eq([])
      end

      it "defaults optional fields to nil" do
        definition = described_class.from_file(agent_path)
        expect(definition.model).to be_nil
        expect(definition.color).to be_nil
        expect(definition.max_turns).to be_nil
      end
    end

    context "with tool name normalization" do
      before do
        File.write(agent_path, <<~MD)
          ---
          name: normalize-test
          description: Tests normalization
          tools: Read, BASH, Web_Get, read
          ---

          Prompt.
        MD
      end

      it "lowercases tool names" do
        definition = described_class.from_file(agent_path)
        expect(definition.tools).to include("read", "bash", "web_get")
      end

      it "deduplicates tool names" do
        definition = described_class.from_file(agent_path)
        expect(definition.tools.count("read")).to eq(1)
      end
    end

    context "with missing required fields" do
      it "raises InvalidDefinitionError when name is missing" do
        File.write(agent_path, <<~MD)
          ---
          description: No name agent
          ---

          Prompt.
        MD

        expect { described_class.from_file(agent_path) }
          .to raise_error(Agents::InvalidDefinitionError, /Missing required field 'name'/)
      end

      it "raises InvalidDefinitionError when description is missing" do
        File.write(agent_path, <<~MD)
          ---
          name: no-desc
          ---

          Prompt.
        MD

        expect { described_class.from_file(agent_path) }
          .to raise_error(Agents::InvalidDefinitionError, /Missing required field 'description'/)
      end
    end

    context "with malformed content" do
      it "raises InvalidDefinitionError when frontmatter is missing entirely" do
        File.write(agent_path, "Just some markdown without frontmatter.")

        expect { described_class.from_file(agent_path) }
          .to raise_error(Agents::InvalidDefinitionError, /Missing YAML frontmatter/)
      end

      it "raises InvalidDefinitionError when frontmatter is not a YAML mapping" do
        File.write(agent_path, <<~MD)
          ---
          - just
          - a list
          ---

          Prompt.
        MD

        expect { described_class.from_file(agent_path) }
          .to raise_error(Agents::InvalidDefinitionError, /not a valid YAML mapping/)
      end
    end

    context "with empty body" do
      before do
        File.write(agent_path, <<~MD)
          ---
          name: empty-body
          description: Agent with empty body
          tools: read
          ---
        MD
      end

      it "sets prompt to empty string" do
        definition = described_class.from_file(agent_path)
        expect(definition.prompt).to eq("")
      end
    end
  end
end
