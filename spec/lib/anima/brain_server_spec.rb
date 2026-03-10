# frozen_string_literal: true

require "spec_helper"
require "anima/brain_server"

RSpec.describe Anima::BrainServer do
  subject(:server) { described_class.new(environment: "test") }

  describe "#initialize" do
    it "stores the environment" do
      expect(server.environment).to eq("test")
    end
  end

  describe "PUMA_PORT" do
    it "defaults to 42134" do
      expect(described_class::PUMA_PORT).to eq(42134)
    end
  end

  describe "#run" do
    before do
      allow(server).to receive(:prepare_databases)
      allow(server).to receive(:trap_signals)
      allow(server).to receive(:start_processes)
      allow(server).to receive(:wait_for_processes)
    end

    it "prepares databases before starting processes" do
      call_order = []
      allow(server).to receive(:prepare_databases) { call_order << :prepare }
      allow(server).to receive(:start_processes) { call_order << :start }

      server.run

      expect(call_order).to eq([:prepare, :start])
    end

    it "traps signals" do
      server.run
      expect(server).to have_received(:trap_signals)
    end

    it "waits for processes to exit" do
      server.run
      expect(server).to have_received(:wait_for_processes)
    end
  end
end
