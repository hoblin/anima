# frozen_string_literal: true

require "spec_helper"
require "tui/decorators/base_decorator"
require "tui/decorators/read_file_decorator"
require "tui/decorators/edit_file_decorator"
require "tui/decorators/write_decorator"
require "tui/decorators/web_get_decorator"
require "tui/decorators/list_files_decorator"
require "tui/decorators/search_files_decorator"

RSpec.describe "Tool-specific decorators" do
  let(:tui) do
    stub = Object.new
    def stub.style(fg: nil, modifiers: nil) = {fg: fg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe TUI::Decorators::ReadFileDecorator do
    it "renders with page icon in cyan" do
      data = {"role" => "tool_call", "tool" => "read_file", "input" => "/app/models/user.rb"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4C4}") # page icon
      expect(header).to include("read_file")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("cyan")
    end

    it "renders response in dark gray" do
      data = {"role" => "tool_response", "tool" => "read_file", "content" => "file contents", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("dark_gray")
    end
  end

  describe TUI::Decorators::EditFileDecorator do
    it "renders with pencil icon in yellow" do
      data = {"role" => "tool_call", "tool" => "edit_file", "input" => "/app/models/user.rb"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u270F\uFE0F") # pencil icon
      expect(header).to include("edit_file")

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("yellow")
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
  end

  describe TUI::Decorators::ListFilesDecorator do
    it "renders with folder icon in cyan" do
      data = {"role" => "tool_call", "tool" => "list_files", "input" => "/app/models"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F4C1}") # folder icon

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("cyan")
    end

    it "renders response in dark gray" do
      data = {"role" => "tool_response", "tool" => "list_files", "content" => "user.rb\npost.rb", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("dark_gray")
    end
  end

  describe TUI::Decorators::SearchFilesDecorator do
    it "renders with magnifying glass icon in magenta" do
      data = {"role" => "tool_call", "tool" => "search_files", "input" => "def authenticate"}
      lines = described_class.new(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F50D}") # magnifying glass

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("magenta")
    end

    it "renders response in dark gray" do
      data = {"role" => "tool_response", "tool" => "search_files", "content" => "found matches", "success" => true}
      lines = described_class.new(data).render_response(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("dark_gray")
    end
  end
end
