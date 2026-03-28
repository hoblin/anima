# frozen_string_literal: true

require "rails_helper"

RSpec.describe Anima::EncryptionKeys do
  let(:tmp_dir) { Dir.mktmpdir }
  let(:key_file) { File.join(tmp_dir, "encryption.key") }

  before { described_class.key_file = key_file }
  after do
    described_class.key_file = nil
    FileUtils.rm_rf(tmp_dir)
  end

  describe ".load_or_generate" do
    context "when key file does not exist" do
      it "generates keys and writes the file" do
        keys = described_class.load_or_generate

        expect(keys).to include(:primary_key, :deterministic_key, :key_derivation_salt)
        expect(File.exist?(key_file)).to be true
      end

      it "sets 0600 permissions on the key file" do
        described_class.load_or_generate

        mode = File.stat(key_file).mode & 0o777
        expect(mode).to eq(0o600)
      end
    end

    context "when key file already exists" do
      before { described_class.generate_and_save }

      it "loads existing keys" do
        original = described_class.load_or_generate
        reloaded = described_class.load_or_generate

        expect(reloaded[:primary_key]).to eq(original[:primary_key])
      end
    end
  end

  describe ".generate_and_save" do
    it "returns all three required keys" do
      keys = described_class.generate_and_save

      expect(keys[:primary_key]).to be_present
      expect(keys[:deterministic_key]).to be_present
      expect(keys[:key_derivation_salt]).to be_present
    end

    it "generates Base64-encoded 32-byte values" do
      keys = described_class.generate_and_save

      keys.each_value do |value|
        decoded = Base64.strict_decode64(value)
        expect(decoded.bytesize).to eq(32)
      end
    end
  end
end
