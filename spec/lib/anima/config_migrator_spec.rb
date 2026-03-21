# frozen_string_literal: true

require "spec_helper"
require "anima/config_migrator"
require "tmpdir"

RSpec.describe Anima::ConfigMigrator do
  let(:tmp_dir) { Pathname.new(Dir.mktmpdir("anima-migrator-test-")) }
  let(:config_path) { tmp_dir.join("config.toml") }
  let(:template_path) { File.expand_path("../../../templates/config.toml", __dir__) }
  let(:anima_home) { tmp_dir.to_s }
  let(:migrator) do
    described_class.new(
      config_path: config_path.to_s,
      template_path: template_path,
      anima_home: anima_home
    )
  end

  after { FileUtils.rm_rf(tmp_dir) }

  def write_config(content)
    config_path.write(content)
  end

  def full_default_config
    File.read(template_path).gsub("{{ANIMA_HOME}}") { anima_home }
  end

  describe "#run" do
    context "when config file does not exist" do
      it "returns :not_found status" do
        result = migrator.run

        expect(result.status).to eq(:not_found)
        expect(result.additions).to be_empty
      end
    end

    context "when config is already up to date" do
      it "returns :up_to_date status without modifying the file" do
        write_config(full_default_config)
        original_content = config_path.read

        result = migrator.run

        expect(result.status).to eq(:up_to_date)
        expect(result.additions).to be_empty
        expect(config_path.read).to eq(original_content)
      end
    end

    context "when an entire section is missing" do
      it "appends the section with its separator comment and keys" do
        config = full_default_config.gsub(
          /# ─── Analytical Brain.*\z/m,
          ""
        )
        write_config(config)

        result = migrator.run

        expect(result.status).to eq(:updated)
        expect(result.additions.map { |a| [a.section, a.key] }).to contain_exactly(
          ["analytical_brain", "max_tokens"],
          ["analytical_brain", "blocking_on_user_message"],
          ["analytical_brain", "blocking_on_agent_message"],
          ["analytical_brain", "event_window"],
          ["mneme", "max_tokens"],
          ["mneme", "viewport_fraction"],
          ["mneme", "l1_budget_fraction"],
          ["mneme", "l2_budget_fraction"],
          ["mneme", "l2_snapshot_threshold"],
          ["mneme", "pinned_budget_fraction"],
          ["recall", "max_results"],
          ["recall", "budget_fraction"],
          ["recall", "max_snippet_tokens"]
        )

        updated = config_path.read
        expect(updated).to include("[analytical_brain]")
        expect(updated).to include("# ─── Analytical Brain")
        expect(updated).to include("max_tokens = 4096")
        expect(updated).to include("event_window = 20")
        expect(updated).to include("[mneme]")
      end
    end

    context "when a key is missing from an existing section" do
      it "inserts the key with its comment into the section" do
        config = full_default_config.lines.reject { |l|
          l.match?(/^token_budget\s*=/) ||
            l.include?("Context window budget")
        }.join
        write_config(config)

        result = migrator.run

        expect(result.status).to eq(:updated)
        expect(result.additions.size).to eq(1)
        expect(result.additions.first.section).to eq("llm")
        expect(result.additions.first.key).to eq("token_budget")
        expect(result.additions.first.value).to eq(190_000)

        updated = config_path.read
        expect(updated).to include("token_budget = 190_000")
        expect(updated).to include("Context window budget")
      end
    end

    context "when multiple sections are missing" do
      it "appends all missing sections" do
        config = full_default_config
          .gsub(/# ─── Paths.*# ─── Session/m, "# ─── Session")
          .gsub(/# ─── Analytical Brain.*\z/m, "")
        write_config(config)

        result = migrator.run

        sections = result.additions.map(&:section).uniq
        expect(sections).to contain_exactly("paths", "analytical_brain", "mneme", "recall")

        updated = config_path.read
        expect(updated).to include("[paths]")
        expect(updated).to include("[analytical_brain]")
        expect(updated).to include("[mneme]")
      end
    end

    context "with user-customized values" do
      it "preserves existing user values" do
        config = full_default_config
          .sub('model = "claude-opus-4-6"', 'model = "claude-haiku-4-5"')
          .sub("max_tokens = 8192", "max_tokens = 16384")
          .gsub(/# ─── Analytical Brain.*\z/m, "")
        write_config(config)

        migrator.run

        updated = config_path.read
        expect(updated).to include('model = "claude-haiku-4-5"')
        expect(updated).to include("max_tokens = 16384")
        expect(updated).to include("[analytical_brain]")
      end
    end

    context "with boolean false values in user config" do
      it "does not treat false as missing" do
        config = full_default_config.sub(
          "blocking_on_user_message = true",
          "blocking_on_user_message = false"
        )
        write_config(config)

        result = migrator.run

        expect(result.status).to eq(:up_to_date)
      end
    end

    context "with template placeholder interpolation" do
      it "resolves {{ANIMA_HOME}} to the configured path" do
        config = full_default_config.gsub(/# ─── Paths.*# ─── Session/m, "# ─── Session")
        write_config(config)

        migrator.run

        updated = config_path.read
        expect(updated).to include("soul = \"#{anima_home}/soul.md\"")
      end
    end
  end

  describe "Result" do
    it "exposes status and additions" do
      result = described_class::Result.new(
        status: :updated,
        additions: [described_class::Addition.new(section: "llm", key: "model", value: "test")]
      )

      expect(result.status).to eq(:updated)
      expect(result.additions.size).to eq(1)
      expect(result.additions.first.section).to eq("llm")
    end
  end

  describe "idempotency" do
    it "returns :up_to_date on second run" do
      config = full_default_config.gsub(/# ─── Analytical Brain.*\z/m, "")
      write_config(config)

      first_result = migrator.run
      expect(first_result.status).to eq(:updated)

      second_result = migrator.run
      expect(second_result.status).to eq(:up_to_date)
    end
  end

  describe "output validity" do
    it "produces valid TOML after migration" do
      config = full_default_config
        .gsub(/# ─── Paths.*# ─── Session/m, "# ─── Session")
        .gsub(/# ─── Analytical Brain.*\z/m, "")
      write_config(config)

      migrator.run

      expect { TomlRB.parse(config_path.read) }.not_to raise_error
      parsed = TomlRB.parse(config_path.read)
      expect(parsed).to have_key("paths")
      expect(parsed).to have_key("analytical_brain")
      expect(parsed["paths"]["soul"]).to eq("#{anima_home}/soul.md")
    end
  end
end
