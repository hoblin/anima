# frozen_string_literal: true

require "rails_helper"

RSpec.describe Skills::Definition do
  describe ".from_file" do
    let(:tmp_dir) { Dir.mktmpdir }
    let(:skill_path) { File.join(tmp_dir, "test-skill.md") }

    after { FileUtils.remove_entry(tmp_dir) }

    context "with a valid definition file" do
      before do
        File.write(skill_path, <<~MD)
          ---
          name: test-skill
          description: A test skill for specs
          ---

          # Test Skill

          This is a test skill with knowledge content.

          ## Guidelines
          - Be thorough
        MD
      end

      it "parses name from frontmatter" do
        definition = described_class.from_file(skill_path)
        expect(definition.name).to eq("test-skill")
      end

      it "parses description from frontmatter" do
        definition = described_class.from_file(skill_path)
        expect(definition.description).to eq("A test skill for specs")
      end

      it "extracts the Markdown body as knowledge content" do
        definition = described_class.from_file(skill_path)
        expect(definition.content).to include("# Test Skill")
        expect(definition.content).to include("## Guidelines")
      end

      it "records the source file path" do
        definition = described_class.from_file(skill_path)
        expect(definition.source_path).to eq(skill_path)
      end
    end

    context "with missing frontmatter" do
      before { File.write(skill_path, "No frontmatter here") }

      it "raises InvalidDefinitionError" do
        expect { described_class.from_file(skill_path) }
          .to raise_error(Skills::InvalidDefinitionError, /Missing YAML frontmatter/)
      end
    end

    context "with invalid YAML frontmatter" do
      before do
        File.write(skill_path, <<~MD)
          ---
          - not a mapping
          ---

          Content
        MD
      end

      it "raises InvalidDefinitionError" do
        expect { described_class.from_file(skill_path) }
          .to raise_error(Skills::InvalidDefinitionError, /not a valid YAML mapping/)
      end
    end

    context "with missing required fields" do
      before do
        File.write(skill_path, <<~MD)
          ---
          name: incomplete
          ---

          Content
        MD
      end

      it "raises InvalidDefinitionError for missing description" do
        expect { described_class.from_file(skill_path) }
          .to raise_error(Skills::InvalidDefinitionError, /Missing required field 'description'/)
      end
    end

    context "with whitespace-only required fields" do
      before do
        File.write(skill_path, <<~MD)
          ---
          name: "  "
          description: valid
          ---

          Content
        MD
      end

      it "raises InvalidDefinitionError for blank name" do
        expect { described_class.from_file(skill_path) }
          .to raise_error(Skills::InvalidDefinitionError, /Missing required field 'name'/)
      end
    end

    context "with extra whitespace in fields" do
      before do
        File.write(skill_path, <<~MD)
          ---
          name: "  padded-name  "
          description: "  padded description  "
          ---

          Content
        MD
      end

      it "strips whitespace from name and description" do
        definition = described_class.from_file(skill_path)
        expect(definition.name).to eq("padded-name")
        expect(definition.description).to eq("padded description")
      end
    end
  end
end
