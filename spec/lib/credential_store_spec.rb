# frozen_string_literal: true

require "rails_helper"

RSpec.describe CredentialStore do
  describe ".write" do
    it "stores a credential in the secrets table" do
      described_class.write("mcp", "api_key" => "sk-xxx")

      expect(Secret.read("mcp", "api_key")).to eq("sk-xxx")
    end

    it "preserves existing keys in the same namespace" do
      described_class.write("mcp", "existing_key" => "old-value")
      described_class.write("mcp", "new_key" => "new-value")

      expect(Secret.read("mcp", "existing_key")).to eq("old-value")
      expect(Secret.read("mcp", "new_key")).to eq("new-value")
    end

    it "updates an existing key" do
      described_class.write("mcp", "api_key" => "old")
      described_class.write("mcp", "api_key" => "new")

      expect(Secret.read("mcp", "api_key")).to eq("new")
      expect(Secret.where(namespace: "mcp", key: "api_key").count).to eq(1)
    end
  end

  describe ".read" do
    it "reads a credential from the secrets table" do
      Secret.write("mcp", "api_key" => "sk-xxx")

      expect(described_class.read("mcp", "api_key")).to eq("sk-xxx")
    end

    it "returns nil when credential does not exist" do
      expect(described_class.read("mcp", "missing")).to be_nil
    end
  end

  describe ".list" do
    it "returns keys under the namespace" do
      Secret.write("mcp", "api_key" => "sk-xxx")
      Secret.write("mcp", "token" => "tok")

      expect(described_class.list("mcp")).to contain_exactly("api_key", "token")
    end

    it "returns empty array when namespace has no entries" do
      expect(described_class.list("mcp")).to eq([])
    end
  end

  describe ".remove" do
    it "removes the key from the namespace" do
      Secret.write("mcp", "api_key" => "sk-xxx")
      Secret.write("mcp", "token" => "tok")

      described_class.remove("mcp", "api_key")

      expect(Secret.read("mcp", "api_key")).to be_nil
      expect(Secret.read("mcp", "token")).to eq("tok")
    end

    it "is a no-op when the key does not exist" do
      expect { described_class.remove("mcp", "missing") }.not_to raise_error
    end
  end
end
