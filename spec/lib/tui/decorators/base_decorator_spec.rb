# frozen_string_literal: true

require "spec_helper"
require "tui/decorators/base_decorator"
require "tui/decorators/bash_decorator"
require "tui/decorators/read_decorator"
require "tui/decorators/edit_decorator"
require "tui/decorators/write_decorator"
require "tui/decorators/web_get_decorator"
require "tui/decorators/think_decorator"

RSpec.describe TUI::Decorators::BaseDecorator do
  # Lightweight TUI stub — returns plain data structures instead of
  # RatatuiRuby native objects, so we can assert on content and style.
  let(:tui) do
    stub = Object.new
    def stub.style(fg: nil, bg: nil, modifiers: nil) = {fg: fg, bg: bg, modifiers: modifiers}
    def stub.span(content:, style: nil) = {content: content, style: style}
    def stub.line(spans:) = {spans: spans}
    stub
  end

  describe ".for" do
    it "returns BashDecorator for bash tool calls" do
      data = {"role" => "tool_call", "tool" => "bash", "input" => "$ ls"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::BashDecorator)
    end

    it "returns ReadDecorator for read_file tool calls" do
      data = {"role" => "tool_call", "tool" => "read_file", "input" => "/app/models/user.rb"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::ReadDecorator)
    end

    it "returns EditDecorator for edit_file tool calls" do
      data = {"role" => "tool_call", "tool" => "edit_file", "input" => "/app/models/user.rb"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::EditDecorator)
    end

    it "returns WriteDecorator for write_file tool calls" do
      data = {"role" => "tool_call", "tool" => "write_file", "input" => "/tmp/output.txt"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::WriteDecorator)
    end

    it "returns WebGetDecorator for web_get tool calls" do
      data = {"role" => "tool_call", "tool" => "web_get", "input" => "GET https://example.com"}

      expect(described_class.for(data)).to be_a(TUI::Decorators::WebGetDecorator)
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

    it "renders multiline input indented with NBSP" do
      data = {"role" => "tool_call", "tool" => "custom", "input" => "line1\nline2"}
      lines = described_class.for(data).render_call(tui)

      expect(lines.length).to eq(3) # header + 2 input lines
      expect(lines[1][:spans].first[:content]).to eq("\u00a0\u00a0line1")
      expect(lines[2][:spans].first[:content]).to eq("\u00a0\u00a0line2")
    end

    it "preserves embedded indentation in tool input" do
      data = {"role" => "tool_call", "tool" => "custom", "input" => "{\n  \"key\": \"val\"\n}"}
      lines = described_class.for(data).render_call(tui)

      expect(lines[2][:spans].first[:content]).to eq("\u00a0\u00a0\u00a0\u00a0\"key\": \"val\"")
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

    it "renders token count as a separate color-coded span" do
      data = {"role" => "tool_response", "content" => "out", "success" => true, "tokens" => 42, "estimated" => true}
      lines = described_class.for(data).render_response(tui)

      token_span = lines.first[:spans][1]
      expect(token_span[:content]).to include("[~42 tok]")
      expect(token_span[:style][:fg]).to eq("dark_gray") # < 1k tokens
    end

    it "uses yellow for token counts between 3k and 10k" do
      data = {"role" => "tool_response", "content" => "out", "success" => true, "tokens" => 5000}
      lines = described_class.for(data).render_response(tui)

      token_span = lines.first[:spans][1]
      expect(token_span[:style][:fg]).to eq("yellow")
    end

    it "uses red for token counts over 20k" do
      data = {"role" => "tool_response", "content" => "out", "success" => true, "tokens" => 25_000}
      lines = described_class.for(data).render_response(tui)

      token_span = lines.first[:spans][1]
      expect(token_span[:style][:fg]).to eq("red")
    end

    it "renders multiline response continuation with NBSP indent" do
      data = {"role" => "tool_response", "content" => "first\nsecond\nthird", "success" => true}
      lines = described_class.for(data).render_response(tui)

      expect(lines.length).to eq(3)
      expect(lines[1][:spans].first[:content]).to eq("\u00a0\u00a0\u00a0\u00a0second")
      expect(lines[2][:spans].first[:content]).to eq("\u00a0\u00a0\u00a0\u00a0third")
    end
  end

  describe "#color" do
    it "uses unified magenta for all tool call headers" do
      data = {"role" => "tool_call", "tool" => "custom_tool", "input" => "param data"}
      lines = described_class.for(data).render_call(tui)

      style = lines.first[:spans].first[:style]
      expect(style[:fg]).to eq("magenta")
    end
  end

  describe "pending state" do
    let(:muted_color) { TUI::Settings.theme_color_muted }

    it "dims tool_call headers when status is pending so per-tool subclass colors don't have to know" do
      data = {"role" => "tool_call", "tool" => "bash", "input" => "$ ls", "status" => "pending"}
      lines = TUI::Decorators::BashDecorator.new(data).render_call(tui)

      expect(lines.first[:spans].first[:style][:fg]).to eq(muted_color)
    end

    it "dims tool_response output when status is pending — even subclasses with their own response_color" do
      data = {"role" => "tool_response", "tool" => "bash", "content" => "ok", "success" => true, "status" => "pending"}
      lines = TUI::Decorators::BashDecorator.new(data).render_response(tui)

      expect(lines.first[:spans].first[:style][:fg]).to eq(muted_color)
    end

    it "leaves bash response color (success green) alone when not pending" do
      data = {"role" => "tool_response", "tool" => "bash", "content" => "ok", "success" => true}
      lines = TUI::Decorators::BashDecorator.new(data).render_response(tui)

      expect(lines.first[:spans].first[:style][:fg]).not_to eq(muted_color)
    end
  end
end
