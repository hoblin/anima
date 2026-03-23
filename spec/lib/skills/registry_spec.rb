# frozen_string_literal: true

require "rails_helper"

RSpec.describe Skills::Registry do
  let(:registry) { described_class.new }
  let(:tmp_dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp_dir) }

  def write_skill(dir, filename, name:, description:, content: "Knowledge content")
    File.write(File.join(dir, filename), <<~MD)
      ---
      name: #{name}
      description: "#{description}"
      ---

      #{content}
    MD
  end

  def write_directory_skill(dir, skill_name, description:, content: "Knowledge content")
    skill_dir = File.join(dir, skill_name)
    FileUtils.mkdir_p(skill_dir)
    File.write(File.join(skill_dir, "SKILL.md"), <<~MD)
      ---
      name: #{skill_name}
      description: "#{description}"
      ---

      #{content}
    MD
    skill_dir
  end

  describe "#load_directory" do
    it "loads flat .md files from the directory" do
      write_skill(tmp_dir, "testing.md", name: "testing", description: "Testing patterns")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("testing")).to be_a(Skills::Definition)
    end

    it "loads directory-based skills with SKILL.md" do
      write_directory_skill(tmp_dir, "my-skill", description: "Directory skill")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("my-skill")).to be_a(Skills::Definition)
    end

    it "loads both flat and directory-based skills" do
      write_skill(tmp_dir, "flat.md", name: "flat", description: "Flat skill")
      write_directory_skill(tmp_dir, "nested", description: "Nested skill")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(2)
      expect(registry.find("flat")).to be_present
      expect(registry.find("nested")).to be_present
    end

    it "skips invalid definition files with a warning" do
      File.write(File.join(tmp_dir, "bad.md"), "No frontmatter here")
      write_skill(tmp_dir, "good.md", name: "good", description: "Valid skill")

      expect(Rails.logger).to receive(:warn).with(/Skipping invalid skill definition/)

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("good")).to be_a(Skills::Definition)
    end

    it "skips invalid directory-based skills with a warning" do
      bad_dir = File.join(tmp_dir, "bad-skill")
      FileUtils.mkdir_p(bad_dir)
      File.write(File.join(bad_dir, "SKILL.md"), "No frontmatter here")
      write_directory_skill(tmp_dir, "good-skill", description: "Valid nested skill")

      expect(Rails.logger).to receive(:warn).with(/Skipping invalid skill definition/)

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("good-skill")).to be_a(Skills::Definition)
    end

    it "skips non-existent directories without error" do
      registry.load_directory("/nonexistent/path")
      expect(registry.size).to eq(0)
    end

    it "loads multiple skill files" do
      write_skill(tmp_dir, "a.md", name: "alpha", description: "Alpha skill")
      write_skill(tmp_dir, "b.md", name: "beta", description: "Beta skill")

      registry.load_directory(tmp_dir)

      expect(registry.size).to eq(2)
    end
  end

  describe "#load_all" do
    it "loads from both built-in and user directories" do
      builtin_dir = Dir.mktmpdir
      user_dir = Dir.mktmpdir

      write_skill(builtin_dir, "builtin.md", name: "builtin", description: "Built-in skill")
      write_skill(user_dir, "custom.md", name: "custom", description: "User skill")

      stub_const("Skills::Registry::BUILTIN_DIR", builtin_dir)

      registry.load_directory(builtin_dir)
      registry.load_directory(user_dir)

      expect(registry.size).to eq(2)
      expect(registry.find("builtin")).to be_present
      expect(registry.find("custom")).to be_present
    ensure
      FileUtils.remove_entry(builtin_dir)
      FileUtils.remove_entry(user_dir)
    end

    it "allows user skills to override built-in ones by name" do
      builtin_dir = Dir.mktmpdir
      user_dir = Dir.mktmpdir

      write_skill(builtin_dir, "shared.md", name: "shared", description: "Built-in version")
      write_skill(user_dir, "shared.md", name: "shared", description: "User version")

      registry.load_directory(builtin_dir)
      registry.load_directory(user_dir)

      expect(registry.size).to eq(1)
      expect(registry.find("shared").description).to eq("User version")
    ensure
      FileUtils.remove_entry(builtin_dir)
      FileUtils.remove_entry(user_dir)
    end
  end

  describe "#find" do
    it "returns the skill definition when found" do
      write_skill(tmp_dir, "test.md", name: "test", description: "Test skill")
      registry.load_directory(tmp_dir)

      expect(registry.find("test")).to be_a(Skills::Definition)
    end

    it "returns nil when skill not found" do
      expect(registry.find("nonexistent")).to be_nil
    end
  end

  describe "#catalog" do
    it "returns name => description hash" do
      write_skill(tmp_dir, "a.md", name: "alpha", description: "Alpha desc")
      write_skill(tmp_dir, "b.md", name: "beta", description: "Beta desc")
      registry.load_directory(tmp_dir)

      expect(registry.catalog).to eq("alpha" => "Alpha desc", "beta" => "Beta desc")
    end

    it "returns empty hash when no skills loaded" do
      expect(registry.catalog).to eq({})
    end
  end

  describe "#available_names" do
    it "returns array of skill names" do
      write_skill(tmp_dir, "a.md", name: "alpha", description: "Alpha")
      write_skill(tmp_dir, "b.md", name: "beta", description: "Beta")
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

    it "loads built-in skills from both flat files and skill directories" do
      instance = described_class.instance
      expect(instance.find("gh-issue")).to be_present, "flat skill not loaded"
      expect(instance.find("activerecord")).to be_present, "directory skill not loaded"
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
