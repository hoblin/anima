# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::Definition do
  describe ".from_file" do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:workflow_path) { File.join(tmp_dir, "test-workflow.md") }

    after { FileUtils.remove_entry(tmp_dir) }

    context "with a valid definition file" do
      before do
        File.write(workflow_path, <<~MD)
          ---
          name: test-workflow
          description: A test workflow for specs
          ---

          ## Context

          This is a test workflow with step-by-step instructions.

          ## Steps
          1. Do the first thing
          2. Do the second thing
        MD
      end

      it "parses name from frontmatter" do
        definition = described_class.from_file(workflow_path)
        expect(definition.name).to eq("test-workflow")
      end

      it "parses description from frontmatter" do
        definition = described_class.from_file(workflow_path)
        expect(definition.description).to eq("A test workflow for specs")
      end

      it "extracts the Markdown body as content" do
        definition = described_class.from_file(workflow_path)
        expect(definition.content).to include("## Context")
        expect(definition.content).to include("## Steps")
      end

      it "records the source file path" do
        definition = described_class.from_file(workflow_path)
        expect(definition.source_path).to eq(workflow_path)
      end
    end

    context "with missing frontmatter" do
      before { File.write(workflow_path, "No frontmatter here") }

      it "raises InvalidDefinitionError" do
        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /Missing YAML frontmatter/)
      end
    end

    context "with invalid YAML frontmatter" do
      before do
        File.write(workflow_path, <<~MD)
          ---
          - not a mapping
          ---

          Content
        MD
      end

      it "raises InvalidDefinitionError" do
        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /not a valid YAML mapping/)
      end
    end

    context "with missing required fields" do
      before do
        File.write(workflow_path, <<~MD)
          ---
          name: incomplete
          ---

          Content
        MD
      end

      it "raises InvalidDefinitionError for missing description" do
        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /Missing required field 'description'/)
      end
    end

    context "with whitespace-only required fields" do
      before do
        File.write(workflow_path, <<~MD)
          ---
          name: "  "
          description: valid
          ---

          Content
        MD
      end

      it "raises InvalidDefinitionError for blank name" do
        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /Missing required field 'name'/)
      end
    end

    context "with invalid workflow name format" do
      it "rejects names with uppercase letters" do
        File.write(workflow_path, <<~MD)
          ---
          name: BadName
          description: valid
          ---

          Content
        MD

        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /Invalid workflow name/)
      end

      it "rejects names with spaces" do
        File.write(workflow_path, <<~MD)
          ---
          name: "bad name"
          description: valid
          ---

          Content
        MD

        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /Invalid workflow name/)
      end

      it "rejects names starting with a hyphen" do
        File.write(workflow_path, <<~MD)
          ---
          name: "-bad"
          description: valid
          ---

          Content
        MD

        expect { described_class.from_file(workflow_path) }
          .to raise_error(Workflows::InvalidDefinitionError, /Invalid workflow name/)
      end

      it "accepts valid underscore-separated names" do
        File.write(workflow_path, <<~MD)
          ---
          name: create_plan
          description: valid
          ---

          Content
        MD

        definition = described_class.from_file(workflow_path)
        expect(definition.name).to eq("create_plan")
      end
    end

    context "with extra whitespace in fields" do
      before do
        File.write(workflow_path, <<~MD)
          ---
          name: "  padded-name  "
          description: "  padded description  "
          ---

          Content
        MD
      end

      it "strips whitespace from name and description" do
        definition = described_class.from_file(workflow_path)
        expect(definition.name).to eq("padded-name")
        expect(definition.description).to eq("padded description")
      end
    end
  end
end
