# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Registry do
  subject(:registry) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp_dir) }

  def write_agent(dir, filename, name:, description:, tools: "read", prompt: "System prompt.")
    File.write(File.join(dir, filename), <<~MD)
      ---
      name: #{name}
      description: #{description}
      tools: #{tools}
      ---

      #{prompt}
    MD
  end

  describe "#load_directory" do
    it "loads .md files from the directory" do
      write_agent(tmp_dir, "analyzer.md", name: "analyzer", description: "Analyzes code")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.get("analyzer")).to be_a(Agents::Definition)
    end

    it "loads multiple agents" do
      write_agent(tmp_dir, "a.md", name: "alpha", description: "First agent")
      write_agent(tmp_dir, "b.md", name: "beta", description: "Second agent")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(2)
      expect(registry.names).to contain_exactly("alpha", "beta")
    end

    it "skips non-existent directories silently" do
      expect { registry.load_directory("/nonexistent/path") }.not_to raise_error
      expect(registry.size).to eq(0)
    end

    it "skips invalid definition files with a warning" do
      File.write(File.join(tmp_dir, "bad.md"), "No frontmatter here")
      write_agent(tmp_dir, "good.md", name: "good", description: "Valid agent")

      expect { registry.load_directory(tmp_dir) }
        .to output(/Skipping invalid agent definition/).to_stderr

      expect(registry.size).to eq(1)
      expect(registry.get("good")).to be_a(Agents::Definition)
    end

    it "skips agents with unknown tool names" do
      write_agent(tmp_dir, "bad.md", name: "bad", description: "Bad agent", tools: "read, teleport")
      write_agent(tmp_dir, "good.md", name: "good", description: "Valid agent")

      expect { registry.load_directory(tmp_dir) }
        .to output(/Unknown tools in 'bad': teleport/).to_stderr

      expect(registry.size).to eq(1)
      expect(registry.get("good")).to be_a(Agents::Definition)
      expect(registry.get("bad")).to be_nil
    end

    it "skips non-.md files" do
      File.write(File.join(tmp_dir, "notes.txt"), "Not an agent")
      write_agent(tmp_dir, "real.md", name: "real", description: "Real agent")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
    end
  end

  describe "user agents override built-in ones" do
    let(:builtin_dir) { Dir.mktmpdir }
    let(:user_dir) { Dir.mktmpdir }

    after {
      FileUtils.remove_entry(builtin_dir)
      FileUtils.remove_entry(user_dir)
    }

    it "replaces a built-in agent when user defines one with the same name" do
      write_agent(builtin_dir, "analyzer.md",
        name: "analyzer", description: "Built-in analyzer", prompt: "Built-in prompt.")
      write_agent(user_dir, "analyzer.md",
        name: "analyzer", description: "Custom analyzer", prompt: "Custom prompt.")

      registry.load_directory(builtin_dir)
      registry.load_directory(user_dir)

      agent = registry.get("analyzer")
      expect(agent.description).to eq("Custom analyzer")
      expect(agent.prompt).to include("Custom prompt")
    end
  end

  describe "#get" do
    it "returns the definition for a registered agent" do
      write_agent(tmp_dir, "test.md", name: "test-agent", description: "Test")
      registry.load_directory(tmp_dir)

      expect(registry.get("test-agent")).to be_a(Agents::Definition)
      expect(registry.get("test-agent").name).to eq("test-agent")
    end

    it "returns nil for unregistered agents" do
      expect(registry.get("nonexistent")).to be_nil
    end
  end

  describe "#catalog" do
    it "returns name-to-description hash" do
      write_agent(tmp_dir, "a.md", name: "alpha", description: "Does alpha things")
      write_agent(tmp_dir, "b.md", name: "beta", description: "Does beta things")
      registry.load_directory(tmp_dir)

      expect(registry.catalog).to eq(
        "alpha" => "Does alpha things",
        "beta" => "Does beta things"
      )
    end

    it "returns empty hash when no agents loaded" do
      expect(registry.catalog).to eq({})
    end
  end

  describe "#names" do
    it "returns array of registered agent names" do
      write_agent(tmp_dir, "x.md", name: "x-agent", description: "X")
      registry.load_directory(tmp_dir)

      expect(registry.names).to eq(["x-agent"])
    end
  end

  describe "#any?" do
    it "returns false when empty" do
      expect(registry.any?).to be false
    end

    it "returns true when agents are loaded" do
      write_agent(tmp_dir, "a.md", name: "a", description: "A")
      registry.load_directory(tmp_dir)

      expect(registry.any?).to be true
    end
  end

  describe ".instance" do
    it "returns a registry loaded with built-in agents" do
      instance = described_class.instance

      expect(instance).to be_a(described_class)
      expect(instance.any?).to be true
    end

    it "returns the same instance on subsequent calls" do
      first = described_class.instance
      second = described_class.instance

      expect(first).to be(second)
    end
  end

  describe ".reload!" do
    it "returns a fresh registry instance" do
      original = described_class.instance
      reloaded = described_class.reload!

      expect(reloaded).to be_a(described_class)
      expect(reloaded).not_to be(original)
    end
  end
end
