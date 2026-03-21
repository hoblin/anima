# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "tui/performance_logger"

RSpec.describe TUI::PerformanceLogger do
  # Use a temp file to avoid interference from dev profiling sessions
  let(:log_path) { File.join(Dir.tmpdir, "tui_perf_test_#{Process.pid}.log") }

  before do
    stub_const("TUI::PerformanceLogger::LOG_PATH", log_path)
    File.delete(log_path) if File.exist?(log_path)
  end

  after do
    File.delete(log_path) if File.exist?(log_path)
  end

  describe "when disabled" do
    subject(:logger) { described_class.new(enabled: false) }

    it "reports disabled" do
      expect(logger).not_to be_enabled
    end

    it "passes through block results from measure" do
      result = logger.measure(:test) { 42 }
      expect(result).to eq(42)
    end

    it "does not create a log file" do
      logger.start_frame
      logger.measure(:test) { nil }
      logger.end_frame

      expect(File.exist?(log_path)).to be false
    end
  end

  describe "when enabled" do
    subject(:logger) { described_class.new(enabled: true) }

    it "reports enabled" do
      expect(logger).to be_enabled
    end

    it "creates a log file on initialization" do
      logger # force initialization
      expect(File.exist?(log_path)).to be true
    end

    it "logs frame timing data" do
      logger.start_frame
      logger.measure(:build_lines) { sleep 0.001 }
      logger.end_frame

      log_content = File.read(log_path)
      expect(log_content).to include("frame=1")
      expect(log_content).to include("build_lines=")
      expect(log_content).to include("total=")
    end

    it "returns block result from measure" do
      logger.start_frame
      result = logger.measure(:test) { "hello" }
      logger.end_frame

      expect(result).to eq("hello")
    end

    it "logs informational messages" do
      logger.info("cache MISS entries=5")

      log_content = File.read(log_path)
      expect(log_content).to include("cache MISS entries=5")
    end

    it "tracks multiple phases per frame" do
      logger.start_frame
      logger.measure(:phase_a) { nil }
      logger.measure(:phase_b) { nil }
      logger.end_frame

      log_content = File.read(log_path)
      expect(log_content).to include("phase_a=")
      expect(log_content).to include("phase_b=")
    end

    it "increments frame counter across frames" do
      2.times do
        logger.start_frame
        logger.end_frame
      end

      log_content = File.read(log_path)
      expect(log_content).to include("frame=1")
      expect(log_content).to include("frame=2")
    end
  end
end
