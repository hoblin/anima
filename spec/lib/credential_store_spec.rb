# frozen_string_literal: true

require "rails_helper"

RSpec.describe CredentialStore do
  let(:creds) { double("credentials") }
  let(:existing_yaml) { "secret_key_base: abc123\n" }

  before do
    allow(creds).to receive(:read).and_return(existing_yaml)
    allow(creds).to receive(:write)
    allow(creds).to receive(:instance_variable_set)
    allow(creds).to receive(:dig)
    allow(Rails.application).to receive(:credentials).and_return(creds)
  end

  describe ".write" do
    it "merges key-value pairs under the given namespace" do
      expect(creds).to receive(:write) do |yaml_content|
        parsed = YAML.safe_load(yaml_content)
        expect(parsed["mcp"]["api_key"]).to eq("sk-xxx")
      end

      described_class.write("mcp", "api_key" => "sk-xxx")
    end

    it "preserves existing credential keys" do
      expect(creds).to receive(:write) do |yaml_content|
        parsed = YAML.safe_load(yaml_content)
        expect(parsed["secret_key_base"]).to eq("abc123")
        expect(parsed["mcp"]["api_key"]).to eq("sk-xxx")
      end

      described_class.write("mcp", "api_key" => "sk-xxx")
    end

    it "preserves existing keys in the same namespace" do
      allow(creds).to receive(:read).and_return("mcp:\n  existing_key: old-value\n")

      expect(creds).to receive(:write) do |yaml_content|
        parsed = YAML.safe_load(yaml_content)
        expect(parsed["mcp"]["existing_key"]).to eq("old-value")
        expect(parsed["mcp"]["new_key"]).to eq("new-value")
      end

      described_class.write("mcp", "new_key" => "new-value")
    end

    it "invalidates Rails credentials cache after write" do
      expect(creds).to receive(:instance_variable_set).with(:@config, nil)

      described_class.write("mcp", "key" => "value")
    end

    it "handles missing credentials file gracefully" do
      allow(creds).to receive(:read)
        .and_raise(ActiveSupport::EncryptedFile::MissingContentError.new("credentials.yml.enc"))

      expect(creds).to receive(:write) do |yaml_content|
        parsed = YAML.safe_load(yaml_content)
        expect(parsed["mcp"]["api_key"]).to eq("sk-xxx")
      end

      described_class.write("mcp", "api_key" => "sk-xxx")
    end
  end

  describe ".read" do
    it "reads a credential via Rails credentials dig" do
      allow(creds).to receive(:dig).with(:mcp, :api_key).and_return("sk-xxx")

      expect(described_class.read("mcp", "api_key")).to eq("sk-xxx")
    end

    it "returns nil when credential does not exist" do
      allow(creds).to receive(:dig).with(:mcp, :missing).and_return(nil)

      expect(described_class.read("mcp", "missing")).to be_nil
    end
  end

  describe ".list" do
    it "returns keys under the namespace" do
      allow(creds).to receive(:dig).with(:mcp).and_return({api_key: "sk-xxx", token: "tok"})

      expect(described_class.list("mcp")).to contain_exactly("api_key", "token")
    end

    it "returns empty array when namespace does not exist" do
      allow(creds).to receive(:dig).with(:mcp).and_return(nil)

      expect(described_class.list("mcp")).to eq([])
    end

    it "returns empty array when namespace is not a hash" do
      allow(creds).to receive(:dig).with(:mcp).and_return("not a hash")

      expect(described_class.list("mcp")).to eq([])
    end
  end

  describe ".remove" do
    it "removes the key from the namespace" do
      allow(creds).to receive(:read).and_return("mcp:\n  api_key: sk-xxx\n  token: tok\n")

      expect(creds).to receive(:write) do |yaml_content|
        parsed = YAML.safe_load(yaml_content)
        expect(parsed["mcp"]).to eq({"token" => "tok"})
      end

      described_class.remove("mcp", "api_key")
    end

    it "removes the namespace when last key is removed" do
      allow(creds).to receive(:read).and_return("mcp:\n  api_key: sk-xxx\n")

      expect(creds).to receive(:write) do |yaml_content|
        parsed = YAML.safe_load(yaml_content)
        expect(parsed).not_to have_key("mcp")
      end

      described_class.remove("mcp", "api_key")
    end

    it "is a no-op when the namespace does not exist" do
      expect(creds).not_to receive(:write)

      described_class.remove("nonexistent", "key")
    end

    it "is a no-op when the key does not exist in the namespace" do
      allow(creds).to receive(:read).and_return("mcp:\n  other_key: value\n")

      expect(creds).not_to receive(:write)

      described_class.remove("mcp", "missing_key")
    end

    it "invalidates Rails credentials cache after removal" do
      allow(creds).to receive(:read).and_return("mcp:\n  api_key: sk-xxx\n")

      expect(creds).to receive(:instance_variable_set).with(:@config, nil)

      described_class.remove("mcp", "api_key")
    end
  end
end
