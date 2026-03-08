# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::WebGet do
  subject(:tool) { described_class.new }

  describe ".tool_name" do
    it "returns web_get" do
      expect(described_class.tool_name).to eq("web_get")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".input_schema" do
    it "defines url as a required string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:url][:type]).to eq("string")
      expect(schema[:required]).to include("url")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "web_get", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    context "with a valid HTTPS URL" do
      before do
        stub_request(:get, "https://example.com")
          .to_return(status: 200, body: "<html><body>Hello World</body></html>")
      end

      it "returns the response body" do
        result = tool.execute("url" => "https://example.com")
        expect(result).to eq("<html><body>Hello World</body></html>")
      end
    end

    context "with a large response" do
      before do
        large_body = "x" * (Tools::WebGet::MAX_RESPONSE_BYTES + 1000)
        stub_request(:get, "https://example.com/large")
          .to_return(status: 200, body: large_body)
      end

      it "truncates the response" do
        result = tool.execute("url" => "https://example.com/large")
        expect(result).to include("[Truncated:")
        expect(result.bytesize).to be < Tools::WebGet::MAX_RESPONSE_BYTES + 200
      end
    end

    context "with an unsupported scheme" do
      it "returns an error for ftp URLs" do
        result = tool.execute("url" => "ftp://files.example.com/file.txt")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Only http and https")
      end

      it "returns an error for file URLs" do
        result = tool.execute("url" => "file:///etc/passwd")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Only http and https")
      end
    end

    context "with an invalid URL" do
      it "returns an error" do
        result = tool.execute("url" => "not a url at all %%")
        expect(result).to be_a(Hash)
        expect(result[:error]).to be_a(String)
      end
    end

    context "when the request times out" do
      before do
        stub_request(:get, "https://slow.example.com")
          .to_timeout
      end

      it "returns a timeout error" do
        result = tool.execute("url" => "https://slow.example.com")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("timed out")
      end
    end

    context "when the connection is refused" do
      before do
        stub_request(:get, "https://down.example.com")
          .to_raise(Errno::ECONNREFUSED)
      end

      it "returns a connection error" do
        result = tool.execute("url" => "https://down.example.com")
        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Connection refused")
      end
    end
  end
end
