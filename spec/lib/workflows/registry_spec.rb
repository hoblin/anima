# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::Registry do
  let(:registry) { described_class.new }
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp_dir) }

  def write_workflow(dir, filename, name:, description:, content: "Workflow content")
    File.write(File.join(dir, filename), <<~MD)
      ---
      name: #{name}
      description: "#{description}"
      ---

      #{content}
    MD
  end

  describe "#load_directory" do
    it "loads .md files from the directory" do
      write_workflow(tmp_dir, "deploy.md", name: "deploy", description: "Deploy to production")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("deploy")).to be_a(Workflows::Definition)
    end

    it "skips invalid definition files with a warning" do
      File.write(File.join(tmp_dir, "bad.md"), "No frontmatter here")
      write_workflow(tmp_dir, "good.md", name: "good", description: "Valid workflow")

      expect(Rails.logger).to receive(:warn).with(/Skipping invalid workflow definition/)

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("good")).to be_a(Workflows::Definition)
    end

    it "skips non-existent directories without error" do
      registry.load_directory("/nonexistent/path")
      expect(registry.size).to eq(0)
    end

    it "loads multiple workflow files" do
      write_workflow(tmp_dir, "a.md", name: "alpha", description: "Alpha workflow")
      write_workflow(tmp_dir, "b.md", name: "beta", description: "Beta workflow")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(2)
    end
  end

  describe "#load_all" do
    it "loads from both built-in and user directories" do
      builtin_dir = Dir.mktmpdir
      user_dir = Dir.mktmpdir

      write_workflow(builtin_dir, "builtin.md", name: "builtin", description: "Built-in workflow")
      write_workflow(user_dir, "custom.md", name: "custom", description: "User workflow")

      stub_const("Workflows::Registry::BUILTIN_DIR", builtin_dir)
      stub_const("Workflows::Registry::USER_DIR", user_dir)

      registry.load_all

      expect(registry.size).to eq(2)
      expect(registry.find("builtin")).to be_present
      expect(registry.find("custom")).to be_present
    ensure
      FileUtils.remove_entry(builtin_dir)
      FileUtils.remove_entry(user_dir)
    end

    it "allows user workflows to override built-in ones by name" do
      builtin_dir = Dir.mktmpdir
      user_dir = Dir.mktmpdir

      write_workflow(builtin_dir, "shared.md", name: "shared", description: "Built-in version")
      write_workflow(user_dir, "shared.md", name: "shared", description: "User version")

      stub_const("Workflows::Registry::BUILTIN_DIR", builtin_dir)
      stub_const("Workflows::Registry::USER_DIR", user_dir)

      registry.load_all

      expect(registry.size).to eq(1)
      expect(registry.find("shared").description).to eq("User version")
    ensure
      FileUtils.remove_entry(builtin_dir)
      FileUtils.remove_entry(user_dir)
    end
  end

  describe "#find" do
    it "returns the workflow definition when found" do
      write_workflow(tmp_dir, "test.md", name: "test", description: "Test workflow")
      registry.load_directory(tmp_dir)

      expect(registry.find("test")).to be_a(Workflows::Definition)
    end

    it "returns nil when workflow not found" do
      expect(registry.find("nonexistent")).to be_nil
    end
  end

  describe "#catalog" do
    it "returns name => description hash" do
      write_workflow(tmp_dir, "a.md", name: "alpha", description: "Alpha desc")
      write_workflow(tmp_dir, "b.md", name: "beta", description: "Beta desc")
      registry.load_directory(tmp_dir)

      expect(registry.catalog).to eq("alpha" => "Alpha desc", "beta" => "Beta desc")
    end

    it "returns empty hash when no workflows loaded" do
      expect(registry.catalog).to eq({})
    end
  end

  describe "#available_names" do
    it "returns array of workflow names" do
      write_workflow(tmp_dir, "a.md", name: "alpha", description: "Alpha")
      write_workflow(tmp_dir, "b.md", name: "beta", description: "Beta")
      registry.load_directory(tmp_dir)

      expect(registry.available_names).to contain_exactly("alpha", "beta")
    end
  end

  describe ".instance" do
    before { described_class.reload! }

    it "returns a loaded registry" do
      expect(described_class.instance).to be_a(described_class)
      expect(described_class.instance).to be_any
    end

    it "loads built-in workflows" do
      instance = described_class.instance
      expect(instance.find("feature")).to be_present
      expect(instance.find("commit")).to be_present
    end
  end

  describe ".reload!" do
    it "returns a fresh registry" do
      first = described_class.instance
      second = described_class.reload!

      expect(second).not_to equal(first)
    end
  end
end
