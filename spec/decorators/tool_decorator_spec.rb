# frozen_string_literal: true

require "rails_helper"

RSpec.describe ToolDecorator do
  describe ".call" do
    it "passes error hashes through undecorated" do
      error = {error: "something broke"}
      expect(described_class.call("web_get", error)).to eq(error)
    end

    it "dispatches to the registered decorator for web_get" do
      result = {body: '{"a":1}', content_type: "application/json"}
      decorated = described_class.call("web_get", result)

      expect(decorated).to be_a(String)
      expect(decorated).to include("[Converted: JSON → TOON]")
    end

    it "passes through results for tools without a decorator" do
      result = "some output"
      expect(described_class.call("bash", result)).to eq("some output")
    end

    it "passes through string results for unregistered tools" do
      result = "hello"
      expect(described_class.call("unknown_tool", result)).to eq("hello")
    end

    it "passes through non-error hashes unchanged" do
      result = described_class.call("unknown_tool", {data: "value"})
      expect(result).to eq({data: "value"})
    end

    it "composes all sanitizers on dirty input" do
      messy = (+"\e[32mOK\e[0m\x00\x07 result: café \x80").force_encoding("ASCII-8BIT")
      result = described_class.call("bash", messy)

      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to be_valid_encoding
      expect(result).to include("OK")
      expect(result).to include("result:")
      expect(result).not_to include("\e[")
      expect(result).not_to include("\x00")
    end

    it "sanitizes decorated tool results too" do
      html_with_ansi = "<html><body>\e[31mHello\e[0m</body></html>"
      result = described_class.call("web_get", {body: html_with_ansi, content_type: "text/html"})

      expect(result).not_to include("\e[")
    end
  end

  # Unit tests for individual sanitizers — each tested in isolation
  # via send to avoid going through the full .call pipeline.

  describe ".encode_utf8" do
    subject(:encode_utf8) { described_class.send(:encode_utf8, input) }

    context "with ASCII-8BIT input" do
      let(:input) { (+"hello \x80\xFF world").force_encoding("ASCII-8BIT") }

      it "returns valid UTF-8" do
        expect(encode_utf8.encoding).to eq(Encoding::UTF_8)
        expect(encode_utf8).to be_valid_encoding
      end

      it "replaces unmappable bytes with U+FFFD" do
        expect(encode_utf8).to include("\uFFFD")
        expect(encode_utf8).to include("hello")
        expect(encode_utf8).to include("world")
      end
    end

    context "with invalid UTF-8 sequences" do
      let(:input) { (+"valid \xC0\xAF text").force_encoding("UTF-8") }

      it "replaces invalid bytes with U+FFFD" do
        expect(encode_utf8).to be_valid_encoding
        expect(encode_utf8).to include("\uFFFD")
      end
    end

    context "with valid UTF-8 input" do
      let(:input) { "Héllo wörld 日本語 🚀" }

      it "preserves content unchanged" do
        expect(encode_utf8).to eq(input)
      end
    end

    context "with Latin-1 encoded input" do
      let(:input) { (+"caf\xE9").force_encoding("ISO-8859-1") }

      it "transcodes to valid UTF-8" do
        expect(encode_utf8.encoding).to eq(Encoding::UTF_8)
        expect(encode_utf8).to eq("café")
      end
    end
  end

  describe ".strip_ansi" do
    subject(:strip_ansi) { described_class.send(:strip_ansi, input) }

    context "with SGR color codes" do
      let(:input) { "\e[31mERROR\e[0m: something failed" }

      it "strips them" do
        expect(strip_ansi).to eq("ERROR: something failed")
      end
    end

    context "with combined SGR attributes" do
      let(:input) { "\e[1;4;33mWarning\e[0m" }

      it "strips bold, underline, and color in one sequence" do
        expect(strip_ansi).to eq("Warning")
      end
    end

    context "with cursor movement" do
      let(:input) { "\e[2J\e[H\e[10;20Htext here" }

      it "strips clear screen, home, and absolute positioning" do
        expect(strip_ansi).to eq("text here")
      end
    end

    context "with OSC sequences" do
      it "strips BEL-terminated OSC (terminal title)" do
        expect(described_class.send(:strip_ansi, "\e]0;Window Title\aVisible text"))
          .to eq("Visible text")
      end

      it "strips ST-terminated OSC" do
        expect(described_class.send(:strip_ansi, "\e]0;Title\e\\Content"))
          .to eq("Content")
      end
    end

    context "with DEC private mode sequences" do
      let(:input) { "\e[?25lhidden cursor\e[?25h" }

      it "strips show/hide cursor" do
        expect(strip_ansi).to eq("hidden cursor")
      end
    end

    context "with real-world gh output" do
      let(:input) { "\e[1;34m#42\e[0m \e[1mFix the bug\e[0m\n\e[32mOpen\e[0m · 3 comments" }

      it "produces clean readable text" do
        expect(strip_ansi).to eq("#42 Fix the bug\nOpen · 3 comments")
      end
    end

    context "with no escape codes" do
      let(:input) { "plain text with no escapes" }

      it "returns input unchanged" do
        expect(strip_ansi).to eq(input)
      end
    end
  end

  describe ".strip_control_chars" do
    subject(:strip_control) { described_class.send(:strip_control_chars, input) }

    context "with NUL bytes" do
      let(:input) { "hello\x00world" }

      it("strips them") { expect(strip_control).to eq("helloworld") }
    end

    context "with BEL" do
      let(:input) { "alert\x07done" }

      it("strips them") { expect(strip_control).to eq("alertdone") }
    end

    context "with backspace" do
      let(:input) { "typo\x08fixed" }

      it("strips them") { expect(strip_control).to eq("typofixed") }
    end

    context "with carriage return" do
      let(:input) { "line1\rline2" }

      it("strips it") { expect(strip_control).to eq("line1line2") }
    end

    context "with CRLF" do
      let(:input) { "line1\r\nline2\r\n" }

      it "strips CR but preserves LF" do
        expect(strip_control).to eq("line1\nline2\n")
      end
    end

    context "with DEL" do
      let(:input) { "text\x7Fmore" }

      it("strips it") { expect(strip_control).to eq("textmore") }
    end

    context "with newlines" do
      let(:input) { "line1\nline2\n" }

      it("preserves them") { expect(strip_control).to eq(input) }
    end

    context "with tabs" do
      let(:input) { "col1\tcol2\tcol3" }

      it("preserves them") { expect(strip_control).to eq(input) }
    end

    context "with no control characters" do
      let(:input) { "clean text" }

      it("returns input unchanged") { expect(strip_control).to eq(input) }
    end
  end
end
