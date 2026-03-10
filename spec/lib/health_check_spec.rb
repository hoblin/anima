# frozen_string_literal: true

require "spec_helper"
require "json"
require "health_check"

RSpec.describe HealthCheck do
  describe ".call" do
    it "returns 200 status" do
      status, _headers, _body = described_class.call({})
      expect(status).to eq(200)
    end

    it "returns JSON content type" do
      _status, headers, _body = described_class.call({})
      expect(headers["content-type"]).to eq("application/json")
    end

    it "returns ok status in body" do
      _status, _headers, body = described_class.call({})
      parsed = JSON.parse(body.first)
      expect(parsed["status"]).to eq("ok")
    end
  end
end
