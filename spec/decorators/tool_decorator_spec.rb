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

    context "encoding sanitization" do
      it "converts ASCII-8BIT strings to valid UTF-8" do
        binary = (+"hello \x80\xFF world").force_encoding("ASCII-8BIT")
        result = described_class.call("bash", binary)

        expect(result.encoding).to eq(Encoding::UTF_8)
        expect(result).to be_valid_encoding
        expect(result).to include("hello")
        expect(result).to include("world")
      end

      it "replaces invalid UTF-8 bytes with replacement character" do
        invalid_utf8 = (+"valid \xC0\xAF text").force_encoding("UTF-8")
        result = described_class.call("bash", invalid_utf8)

        expect(result).to be_valid_encoding
        expect(result).to include("valid")
        expect(result).to include("text")
        expect(result).to include("\uFFFD")
      end

      it "preserves valid UTF-8 content unchanged" do
        utf8 = "Héllo wörld 日本語 🚀"
        result = described_class.call("bash", utf8)

        expect(result).to eq(utf8)
      end
    end

    context "ANSI escape code stripping" do
      it "strips SGR color codes" do
        ansi = "\e[31mERROR\e[0m: something failed"
        result = described_class.call("bash", ansi)

        expect(result).to eq("ERROR: something failed")
      end

      it "strips bold, underline, and combined SGR sequences" do
        ansi = "\e[1;4;33mWarning\e[0m"
        result = described_class.call("bash", ansi)

        expect(result).to eq("Warning")
      end

      it "strips cursor movement sequences" do
        ansi = "\e[2J\e[H\e[10;20Htext here"
        result = described_class.call("bash", ansi)

        expect(result).to eq("text here")
      end

      it "strips OSC sequences (e.g. terminal title)" do
        osc = "\e]0;Window Title\aVisible text"
        result = described_class.call("bash", osc)

        expect(result).to eq("Visible text")
      end

      it "strips OSC sequences terminated by ST" do
        osc = "\e]0;Title\e\\Content"
        result = described_class.call("bash", osc)

        expect(result).to eq("Content")
      end

      it "strips DEC private mode sequences (show/hide cursor)" do
        ansi = "\e[?25lhidden cursor\e[?25h"
        result = described_class.call("bash", ansi)

        expect(result).to eq("hidden cursor")
      end

      it "handles gh issue view output with heavy ANSI formatting" do
        gh_output = "\e[1;34m#42\e[0m \e[1mFix the bug\e[0m\n\e[32mOpen\e[0m · 3 comments"
        result = described_class.call("bash", gh_output)

        expect(result).to eq("#42 Fix the bug\nOpen · 3 comments")
      end
    end

    context "control character stripping" do
      it "strips NUL bytes" do
        result = described_class.call("bash", "hello\x00world")
        expect(result).to eq("helloworld")
      end

      it "strips BEL characters" do
        result = described_class.call("bash", "alert\x07done")
        expect(result).to eq("alertdone")
      end

      it "strips backspace characters" do
        result = described_class.call("bash", "typo\x08fixed")
        expect(result).to eq("typofixed")
      end

      it "preserves newlines" do
        result = described_class.call("bash", "line1\nline2\n")
        expect(result).to eq("line1\nline2\n")
      end

      it "preserves tabs" do
        result = described_class.call("bash", "col1\tcol2\tcol3")
        expect(result).to eq("col1\tcol2\tcol3")
      end

      it "strips DEL character" do
        result = described_class.call("bash", "text\x7Fmore")
        expect(result).to eq("textmore")
      end

      it "strips carriage return characters" do
        result = described_class.call("bash", "line1\rline2")
        expect(result).to eq("line1line2")
      end

      it "normalizes CRLF to LF" do
        result = described_class.call("bash", "line1\r\nline2\r\n")
        expect(result).to eq("line1\nline2\n")
      end
    end

    context "combined sanitization" do
      it "handles ASCII-8BIT with ANSI codes and control characters" do
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
        # WebGetToolDecorator returns a String; sanitization runs after
        html_with_ansi = "<html><body>\e[31mHello\e[0m</body></html>"
        result = described_class.call("web_get", {body: html_with_ansi, content_type: "text/html"})

        expect(result).not_to include("\e[")
      end
    end

    context "non-string passthrough" do
      it "passes through hash results from WebGet decorator" do
        # WebGetToolDecorator always returns a String, but if a tool
        # returned a non-error hash for some reason, sanitization skips it
        result = described_class.call("unknown_tool", {data: "value"})
        expect(result).to eq({data: "value"})
      end
    end
  end
end
