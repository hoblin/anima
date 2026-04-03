# frozen_string_literal: true

require "spec_helper"
require "tui/decorators/base_decorator"
require "tui/decorators/think_decorator"

RSpec.describe TUI::Decorators::ThinkDecorator do
  before { TUI::Settings.config_path = File.expand_path("../../../../templates/tui.toml", __dir__) }
  after { TUI::Settings.reset! }

  let(:tui) do
    stub = Object.new
    def stub.style(fg: nil, bg: nil, modifiers: nil) = {fg: fg, bg: bg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe "#render_think" do
    it "renders aloud thoughts in dark_gray with thought bubble" do
      data = {"role" => "think", "content" => "Let me check that.", "visibility" => "aloud"}
      lines = described_class.new(data).render_think(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4AD}") # thought balloon
      expect(header).to include("Let me check that.")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("dark_gray")
    end

    it "renders inner thoughts in dark gray" do
      data = {"role" => "think", "content" => "Planning next step", "visibility" => "inner"}
      lines = described_class.new(data).render_think(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("dark_gray")
    end

    it "includes timestamp when present" do
      data = {"role" => "think", "content" => "Thinking", "visibility" => "aloud",
              "timestamp" => 1_709_312_325_000_000_000}
      lines = described_class.new(data).render_think(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to match(/\[\d{2}:\d{2}:\d{2}\]/)
    end

    it "renders multiline content indented with NBSP" do
      data = {"role" => "think", "content" => "line one\nline two\nline three", "visibility" => "aloud"}
      lines = described_class.new(data).render_think(tui)

      expect(lines.length).to eq(3)
      expect(lines[1][:spans].first[:content]).to eq("\u00a0\u00a0line two")
      expect(lines[2][:spans].first[:content]).to eq("\u00a0\u00a0line three")
    end

    it "dispatches correctly from BaseDecorator.for" do
      data = {"role" => "think", "content" => "test", "visibility" => "aloud"}
      decorator = TUI::Decorators::BaseDecorator.for(data)

      expect(decorator).to be_a(described_class)
      lines = decorator.render(tui)
      expect(lines.first[:spans].first[:content]).to include("\u{1F4AD}")
    end
  end
end
