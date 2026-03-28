# frozen_string_literal: true

require "rails_helper"

RSpec.describe Mcp::Secrets do
  before do
    allow(CredentialStore).to receive(:write)
    allow(CredentialStore).to receive(:read)
    allow(CredentialStore).to receive(:list).and_return([])
    allow(CredentialStore).to receive(:remove)
  end

  describe ".set" do
    it "delegates to CredentialStore with mcp namespace" do
      expect(CredentialStore).to receive(:write).with("mcp", "api_key" => "sk-xxx")

      described_class.set("api_key", "sk-xxx")
    end

    it "rejects keys with hyphens" do
      expect {
        described_class.set("my-key", "value")
      }.to raise_error(ArgumentError, /invalid secret key/)
    end

    it "rejects keys with spaces" do
      expect {
        described_class.set("my key", "value")
      }.to raise_error(ArgumentError, /invalid secret key/)
    end

    it "accepts keys with underscores and digits" do
      expect(CredentialStore).to receive(:write).with("mcp", "api_key_2" => "val")

      described_class.set("api_key_2", "val")
    end
  end

  describe ".get" do
    it "delegates to CredentialStore with mcp namespace" do
      expect(CredentialStore).to receive(:read).with("mcp", "api_key").and_return("sk-xxx")

      expect(described_class.get("api_key")).to eq("sk-xxx")
    end

    it "returns nil when secret does not exist" do
      expect(CredentialStore).to receive(:read).with("mcp", "missing").and_return(nil)

      expect(described_class.get("missing")).to be_nil
    end
  end

  describe ".list" do
    it "delegates to CredentialStore with mcp namespace" do
      expect(CredentialStore).to receive(:list).with("mcp").and_return(["api_key", "token"])

      expect(described_class.list).to eq(["api_key", "token"])
    end
  end

  describe ".remove" do
    it "delegates to CredentialStore with mcp namespace" do
      expect(CredentialStore).to receive(:remove).with("mcp", "api_key")

      described_class.remove("api_key")
    end
  end
end
