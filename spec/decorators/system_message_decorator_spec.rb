# frozen_string_literal: true

require "rails_helper"

RSpec.describe SystemMessageDecorator, type: :decorator do
  subject(:decorator) { message.decorate }

  describe "#render_basic" do
    let(:message) { build_stubbed(:message, :system_message, payload: {"content" => "retrying..."}) }

    it "returns nil (hidden in basic mode)" do
      expect(decorator.render_basic).to be_nil
    end
  end

  describe "#render_verbose" do
    let(:ts) { 1_709_312_325_000_000_000 }
    let(:message) { build_stubbed(:message, :system_message, payload: {"content" => "retrying after error"}, timestamp: ts) }

    it "returns structured hash with system role and timestamp" do
      expect(decorator.render_verbose).to eq({role: :system, content: "retrying after error", timestamp: ts})
    end
  end

  describe "#render_debug" do
    let(:ts) { 1_709_312_325_000_000_000 }
    let(:message) { build_stubbed(:message, :system_message, payload: {"content" => "retrying after error"}, timestamp: ts) }

    it "returns the same structure as verbose" do
      expect(decorator.render_debug).to eq({role: :system, content: "retrying after error", timestamp: ts})
    end
  end
end
