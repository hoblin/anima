# frozen_string_literal: true

require "spec_helper"
require "tui/decorators/base_decorator"
require "tui/decorators/bash_decorator"

RSpec.describe TUI::Decorators::BashDecorator do
  let(:tui) do
    stub = Object.new
    def stub.style(fg: nil, bg: nil, modifiers: nil) = {fg: fg, bg: bg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe "#render_call" do
    it "renders with terminal icon" do
      data = {"role" => "tool_call", "tool" => "bash", "input" => "$ git status"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4BB}") # laptop icon
      expect(header).to include("bash")
    end

    it "indents the command input" do
      data = {"role" => "tool_call", "tool" => "bash", "input" => "$ git status"}
      lines = described_class.new(data).render_call(tui)

      expect(lines[1][:spans].first[:content]).to eq("  $ git status")
    end
  end

  describe "#render_response" do
    it "renders success output in green" do
      data = {"role" => "tool_response", "tool" => "bash", "content" => "file.txt", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("green")
    end

    it "renders failure output in red" do
      data = {"role" => "tool_response", "tool" => "bash", "content" => "command not found", "success" => false}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("red")
    end
  end
end
