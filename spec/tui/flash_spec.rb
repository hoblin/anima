# frozen_string_literal: true

require_relative "../../lib/tui/flash"

RSpec.describe TUI::Flash do
  subject(:flash) { described_class.new }

  before { TUI::Settings.config_path = File.expand_path("../../templates/tui.toml", __dir__) }
  after { TUI::Settings.reset! }

  describe "#error / #warning / #info" do
    it "adds entries that appear in any?" do
      expect(flash).to be_empty
      flash.error("Something broke")
      expect(flash).to be_any
    end
  end

  describe "#dismiss!" do
    it "removes all entries" do
      flash.error("err")
      flash.warning("warn")
      flash.dismiss!
      expect(flash).to be_empty
    end
  end

  describe "auto-expiry" do
    it "removes entries after AUTO_DISMISS_SECONDS" do
      flash.error("old error")

      # Stub the monotonic clock to advance past the timeout
      initial_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(initial_time + TUI::Settings.flash_auto_dismiss_seconds + 1)

      expect(flash).to be_empty
    end

    it "keeps entries within the timeout window" do
      flash.error("recent error")

      initial_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      allow(Process).to receive(:clock_gettime)
        .with(Process::CLOCK_MONOTONIC)
        .and_return(initial_time + 1)

      expect(flash).to be_any
    end
  end
end
