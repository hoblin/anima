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
    def stub.style(fg: nil, modifiers: nil) = {fg: fg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe TUI::Decorators::ReadDecorator do
    it "renders with page icon in cyan" do
      data = {"role" => "tool_call", "tool" => "read", "input" => "/app/models/user.rb"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4C4}") # page icon
      expect(header).to include("read")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("cyan")
    end

    it "renders response in dark gray" do
      data = {"role" => "tool_response", "tool" => "read", "content" => "file contents", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("dark_gray")
    end
  end

  describe TUI::Decorators::EditDecorator do
    it "renders with pencil icon in yellow" do
      data = {"role" => "tool_call", "tool" => "edit", "input" => "/app/models/user.rb"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u270F\uFE0F") # pencil icon
      expect(header).to include("edit")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("yellow")
    end

    it "renders response in default white" do
      data = {"role" => "tool_response", "tool" => "edit", "content" => "edited", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("white")
    end
  end

  describe TUI::Decorators::WriteDecorator do
    it "renders with memo icon in yellow" do
      data = {"role" => "tool_call", "tool" => "write", "input" => "/tmp/output.txt"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4DD}") # memo icon
      expect(header).to include("write")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("yellow")
    end

    it "renders response in default white" do
      data = {"role" => "tool_response", "tool" => "write", "content" => "written", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("white")
    end
  end

  describe TUI::Decorators::WebGetDecorator do
    it "renders with globe icon in blue" do
      data = {"role" => "tool_call", "tool" => "web_get", "input" => "GET https://example.com"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F310}") # globe icon
      expect(header).to include("web_get")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("blue")
    end

    it "renders response in default white" do
      data = {"role" => "tool_response", "tool" => "web_get", "content" => "page content", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("white")
    end
  end
end
