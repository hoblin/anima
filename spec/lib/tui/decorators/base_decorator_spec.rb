# frozen_string_literal: true

require "spec_helper"
require "tui/decorators/base_decorator"
require "tui/decorators/bash_decorator"
require "tui/decorators/read_file_decorator"
require "tui/decorators/edit_file_decorator"
require "tui/decorators/write_decorator"
require "tui/decorators/web_fetch_decorator"
require "tui/decorators/list_files_decorator"
require "tui/decorators/search_files_decorator"
require "tui/decorators/think_decorator"

RSpec.describe TUI::Decorators::BaseDecorator do
  # Lightweight TUI stub — returns plain data structures instead of
  # RatatuiRuby native objects, so we can assert on content and style.
  let(:tui) do
    stub = Object.new
    def stub.style(fg: nil, modifiers: nil) = {fg: fg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe ".for" do
    it "returns BashDecorator for bash tool calls" do
      data = {"role" => "tool_call", "tool" => "bash", "input" => "$ ls"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::BashDecorator)
    end

    it "returns ReadFileDecorator for read_file tool calls" do
      data = {"role" => "tool_call", "tool" => "read_file", "input" => "/app/models/user.rb"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::ReadFileDecorator)
    end

    it "returns EditFileDecorator for edit_file tool calls" do
      data = {"role" => "tool_call", "tool" => "edit_file", "input" => "/app/models/user.rb"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::EditFileDecorator)
    end

    it "returns WriteDecorator for write tool calls" do
      data = {"role" => "tool_call", "tool" => "write", "input" => "/tmp/output.txt"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::WriteDecorator)
    end

    it "returns WebFetchDecorator for web_fetch tool calls" do
      data = {"role" => "tool_call", "tool" => "web_fetch", "input" => "GET https://example.com"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::WebFetchDecorator)
    end

    it "returns WebFetchDecorator for web_get tool calls" do
      data = {"role" => "tool_call", "tool" => "web_get", "input" => "GET https://example.com"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::WebFetchDecorator)
    end

    it "returns ListFilesDecorator for list_files tool calls" do
      data = {"role" => "tool_call", "tool" => "list_files", "input" => "/app/models"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::ListFilesDecorator)
    end

    it "returns SearchFilesDecorator for search_files tool calls" do
      data = {"role" => "tool_call", "tool" => "search_files", "input" => "def authenticate"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::SearchFilesDecorator)
    end

    it "returns ThinkDecorator for think role" do
      data = {"role" => "think", "content" => "planning", "visibility" => "aloud"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::ThinkDecorator)
    end

    it "returns BaseDecorator for unknown tools" do
      data = {"role" => "tool_call", "tool" => "custom_tool", "input" => "{}"}
      decorator = described_class.for(data)

      expect(decorator).to be_a(described_class)
      expect(decorator).not_to be_a(TUI::Decorators::BashDecorator)
    end

    it "returns BaseDecorator for tool responses with no tool field" do
      data = {"role" => "tool_response", "content" => "output", "success" => true}

      expect(described_class.for(data)).to be_a(described_class)
    end

    it "returns per-tool decorator for tool responses with tool field" do
      data = {"role" => "tool_response", "tool" => "bash", "content" => "output", "success" => true}

      expect(described_class.for(data)).to be_a(TUI::Decorators::BashDecorator)
    end
  end

  describe "#render" do
    it "dispatches tool_call role to render_call" do
      data = {"role" => "tool_call", "tool" => "custom", "input" => "params"}
      decorator = described_class.for(data)

      expect(decorator).to receive(:render_call).with(tui).and_call_original
      decorator.render(tui)
    end

    it "dispatches tool_response role to render_response" do
      data = {"role" => "tool_response", "content" => "output", "success" => true}
      decorator = described_class.for(data)

      expect(decorator).to receive(:render_response).with(tui).and_call_original
      decorator.render(tui)
    end

    it "dispatches think role to render_think" do
      data = {"role" => "think", "content" => "planning", "visibility" => "aloud"}
      decorator = described_class.for(data)

      expect(decorator).to receive(:render_think).with(tui).and_call_original
      decorator.render(tui)
    end
  end

  describe "#render_call (generic)" do
    it "renders tool name with wrench icon" do
      data = {"role" => "tool_call", "tool" => "custom_tool", "input" => "param data"}
      lines = described_class.for(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("\u{1F527}")
      expect(header).to include("custom_tool")
    end

    it "includes timestamp when present" do
      data = {"role" => "tool_call", "tool" => "custom", "input" => "x", "timestamp" => 1_709_312_325_000_000_000}
      lines = described_class.for(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to match(/\[\d{2}:\d{2}:\d{2}\]/)
    end

    it "includes tool_use_id when present" do
      data = {"role" => "tool_call", "tool" => "custom", "input" => "x", "tool_use_id" => "toolu_abc"}
      lines = described_class.for(data).render_call(tui)

      header = lines.first[:spans].first[:content]
      expect(header).to include("[toolu_abc]")
    end

    it "renders multiline input indented" do
      data = {"role" => "tool_call", "tool" => "custom", "input" => "line1\nline2"}
      lines = described_class.for(data).render_call(tui)

      expect(lines.length).to eq(3) # header + 2 input lines
      expect(lines[1][:spans].first[:content]).to eq("  line1")
      expect(lines[2][:spans].first[:content]).to eq("  line2")
    end
  end

  describe "#render_response (generic)" do
    it "renders success indicator" do
      data = {"role" => "tool_response", "content" => "output", "success" => true}
      lines = described_class.for(data).render_response(tui)

      first_line = lines.first[:spans].first[:content]
      expect(first_line).to include("\u2713") # checkmark
    end

    it "renders failure indicator" do
      data = {"role" => "tool_response", "content" => "error", "success" => false}
      lines = described_class.for(data).render_response(tui)

      first_line = lines.first[:spans].first[:content]
      expect(first_line).to include("\u274C") # error icon
    end

    it "includes tool_use_id when present" do
      data = {"role" => "tool_response", "content" => "out", "success" => true, "tool_use_id" => "toolu_xyz"}
      lines = described_class.for(data).render_response(tui)

      first_line = lines.first[:spans].first[:content]
      expect(first_line).to include("[toolu_xyz]")
    end

    it "includes token count when present" do
      data = {"role" => "tool_response", "content" => "out", "success" => true, "tokens" => 42, "estimated" => true}
      lines = described_class.for(data).render_response(tui)

      first_line = lines.first[:spans].first[:content]
      expect(first_line).to include("[~42 tok]")
    end
  end
end
