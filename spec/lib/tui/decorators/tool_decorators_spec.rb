# frozen_string_literal: true

require "spec_helper"
require "tui/decorators/base_decorator"
require "tui/decorators/read_decorator"
require "tui/decorators/edit_decorator"
require "tui/decorators/write_decorator"
require "tui/decorators/web_get_decorator"

RSpec.describe "Tool-specific decorators" do
  let(:tui) do
    stub = Object.new
    def stub.style(fg: nil, bg: nil, modifiers: nil) = {fg: fg, bg: bg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe TUI::Decorators::ReadDecorator do
    it "renders call with page icon in unified magenta" do
      data = {"role" => "tool_call", "tool" => "read", "input" => "/app/models/user.rb"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4C4}") # page icon
      expect(header).to include("read")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("magenta")
    end

    it "renders response in CRUD Read color (light_blue)" do
      data = {"role" => "tool_response", "tool" => "read", "content" => "file contents", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("light_blue")
    end
  end

  describe TUI::Decorators::EditDecorator do
    it "renders call with pencil icon in unified magenta" do
      data = {"role" => "tool_call", "tool" => "edit", "input" => "/app/models/user.rb"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u270F\uFE0F") # pencil icon
      expect(header).to include("edit")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("magenta")
    end

    it "renders response in CRUD Update color (light_yellow)" do
      data = {"role" => "tool_response", "tool" => "edit", "content" => "edited", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("light_yellow")
    end
  end

  describe TUI::Decorators::WriteDecorator do
    it "renders call with memo icon in unified magenta" do
      data = {"role" => "tool_call", "tool" => "write", "input" => "/tmp/output.txt"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4DD}") # memo icon
      expect(header).to include("write")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("magenta")
    end

    it "renders multi-line content on separate lines" do
      input = "/tmp/soul.md\nline1\nline2\nline3"
      data = {"role" => "tool_call", "tool" => "write", "input" => input}
      lines = described_class.new(data).render_call(tui)

      expect(lines.size).to eq(5)
      expect(lines[1][:spans].first[:content]).to eq("  /tmp/soul.md")
      expect(lines[2][:spans].first[:content]).to eq("  line1")
      expect(lines[3][:spans].first[:content]).to eq("  line2")
      expect(lines[4][:spans].first[:content]).to eq("  line3")
    end

    it "renders response in CRUD Create color (light_green)" do
      data = {"role" => "tool_response", "tool" => "write", "content" => "written", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("light_green")
    end
  end

  describe TUI::Decorators::WebGetDecorator do
    it "renders call with globe icon in unified magenta" do
      data = {"role" => "tool_call", "tool" => "web_get", "input" => "GET https://example.com"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F310}") # globe icon
      expect(header).to include("web_get")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("magenta")
    end

    it "renders response in CRUD Read color (light_blue)" do
      data = {"role" => "tool_response", "tool" => "web_get", "content" => "page content", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("light_blue")
    end
  end
end
