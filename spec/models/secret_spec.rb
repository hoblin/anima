# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secret do
  describe "validations" do
    it "requires namespace" do
      secret = described_class.new(key: "token", value: "sk-xxx")
      expect(secret).not_to be_valid
      expect(secret.errors[:namespace]).to include("can't be blank")
    end

    it "requires key" do
      secret = described_class.new(namespace: "mcp", value: "sk-xxx")
      expect(secret).not_to be_valid
      expect(secret.errors[:key]).to include("can't be blank")
    end

    it "requires value" do
      secret = described_class.new(namespace: "mcp", key: "token")
      expect(secret).not_to be_valid
      expect(secret.errors[:value]).to include("can't be blank")
    end

    it "enforces uniqueness of key within namespace" do
      described_class.create!(namespace: "mcp", key: "token", value: "first")

      duplicate = described_class.new(namespace: "mcp", key: "token", value: "second")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:key]).to include("has already been taken")
    end

    it "allows the same key in different namespaces" do
      described_class.create!(namespace: "mcp", key: "token", value: "mcp-value")
      described_class.create!(namespace: "anthropic", key: "token", value: "anthropic-value")

      expect(described_class.where(key: "token").count).to eq(2)
    end
  end

  describe "encryption" do
    it "encrypts the value column" do
      secret = described_class.create!(namespace: "test", key: "api_key", value: "sk-secret-123")

      # Read raw column value bypassing AR encryption
      raw = ActiveRecord::Base.connection.select_value(
        "SELECT value FROM secrets WHERE id = #{secret.id}"
      )

      expect(raw).not_to eq("sk-secret-123")
      expect(secret.reload.value).to eq("sk-secret-123")
    end
  end

  describe ".read" do
    it "returns the decrypted value" do
      described_class.create!(namespace: "mcp", key: "api_key", value: "sk-xxx")

      expect(described_class.read("mcp", "api_key")).to eq("sk-xxx")
    end

    it "returns nil when not found" do
      expect(described_class.read("mcp", "missing")).to be_nil
    end
  end

  describe ".write" do
    it "creates a new record" do
      described_class.write("mcp", "api_key" => "sk-xxx")

      expect(described_class.read("mcp", "api_key")).to eq("sk-xxx")
    end

    it "updates an existing record" do
      described_class.write("mcp", "api_key" => "old")
      described_class.write("mcp", "api_key" => "new")

      expect(described_class.read("mcp", "api_key")).to eq("new")
      expect(described_class.where(namespace: "mcp", key: "api_key").count).to eq(1)
    end

    it "writes multiple pairs" do
      described_class.write("mcp", "key1" => "val1", "key2" => "val2")

      expect(described_class.read("mcp", "key1")).to eq("val1")
      expect(described_class.read("mcp", "key2")).to eq("val2")
    end

    it "rolls back all writes when any pair fails validation" do
      expect {
        described_class.write("mcp", "good_key" => "val", "bad_key" => "")
      }.to raise_error(ActiveRecord::RecordInvalid)

      expect(described_class.read("mcp", "good_key")).to be_nil
    end
  end

  describe ".list" do
    it "returns keys under a namespace" do
      described_class.write("mcp", "api_key" => "sk-xxx")
      described_class.write("mcp", "token" => "tok")
      described_class.write("other", "unrelated" => "val")

      expect(described_class.list("mcp")).to contain_exactly("api_key", "token")
    end

    it "returns empty array for empty namespace" do
      expect(described_class.list("nonexistent")).to eq([])
    end
  end

  describe ".remove" do
    it "deletes the record" do
      described_class.write("mcp", "api_key" => "sk-xxx")
      described_class.remove("mcp", "api_key")

      expect(described_class.read("mcp", "api_key")).to be_nil
    end

    it "is a no-op when the record does not exist" do
      expect { described_class.remove("mcp", "missing") }.not_to raise_error
    end
  end

  describe ".for_namespace" do
    it "returns only records in the given namespace" do
      described_class.write("mcp", "key1" => "val1")
      described_class.write("anthropic", "key2" => "val2")

      results = described_class.for_namespace("mcp")
      expect(results.pluck(:key)).to eq(["key1"])
    end
  end
end
