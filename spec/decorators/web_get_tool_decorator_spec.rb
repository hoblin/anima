# frozen_string_literal: true

require "rails_helper"

RSpec.describe WebGetToolDecorator do
  subject(:decorator) { described_class.new }

  describe "#call" do
    context "with HTML content" do
      let(:html) do
        <<~HTML
          <html>
          <head><script>var x = 1;</script><style>body{}</style></head>
          <body>
            <nav><a href="/">Home</a></nav>
            <h1>Hello World</h1>
            <p>This is <strong>important</strong> content.</p>
            <footer>Copyright 2026</footer>
          </body>
          </html>
        HTML
      end

      it "converts HTML to Markdown with metadata tag" do
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to start_with("[Converted: HTML → Markdown]")
        expect(result).to include("# Hello World")
        expect(result).to include("**important**")
      end

      it "strips script tags" do
        result = decorator.call(body: html, content_type: "text/html")
        expect(result).not_to include("var x = 1")
      end

      it "strips style tags" do
        result = decorator.call(body: html, content_type: "text/html")
        expect(result).not_to include("body{}")
      end

      it "strips nav elements" do
        result = decorator.call(body: html, content_type: "text/html")
        expect(result).not_to include("Home")
      end

      it "strips footer elements" do
        result = decorator.call(body: html, content_type: "text/html")
        expect(result).not_to include("Copyright")
      end

      it "handles Content-Type with charset parameter" do
        result = decorator.call(body: html, content_type: "text/html; charset=utf-8")
        expect(result).to start_with("[Converted: HTML → Markdown]")
      end
    end

    context "with HTML containing semantic elements" do
      it "converts headers" do
        html = "<h2>Section</h2><p>text</p>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("## Section")
      end

      it "converts lists" do
        html = "<ul><li>one</li><li>two</li></ul>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("- one")
        expect(result).to include("- two")
      end

      it "converts links" do
        html = '<a href="https://example.com">Example</a>'
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("[Example](https://example.com)")
      end

      it "converts code blocks" do
        html = "<pre><code>puts 'hello'</code></pre>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("puts 'hello'")
      end

      it "converts tables" do
        html = "<table><tr><th>Name</th></tr><tr><td>Alice</td></tr></table>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("Name")
        expect(result).to include("Alice")
      end
    end

    context "with JSON content" do
      it "converts JSON to TOON with metadata tag" do
        json = '[{"name":"Alice","age":30},{"name":"Bob","age":25}]'
        result = decorator.call(body: json, content_type: "application/json")

        expect(result).to start_with("[Converted: JSON → TOON]")
        expect(result).not_to include('"name"')
      end

      it "handles simple JSON objects" do
        json = '{"key":"value"}'
        result = decorator.call(body: json, content_type: "application/json")

        expect(result).to include("[Converted: JSON → TOON]")
      end

      it "passes through invalid JSON without metadata tag" do
        broken = "not { valid json"
        result = decorator.call(body: broken, content_type: "application/json")

        expect(result).to eq("not { valid json")
      end
    end

    context "with unknown content types" do
      it "passes through text/plain unchanged" do
        result = decorator.call(body: "plain text", content_type: "text/plain")
        expect(result).to eq("plain text")
      end

      it "passes through application/xml unchanged" do
        xml = "<root><item>data</item></root>"
        result = decorator.call(body: xml, content_type: "application/xml")
        expect(result).to eq(xml)
      end

      it "passes through image/png unchanged" do
        result = decorator.call(body: "binary data", content_type: "image/png")
        expect(result).to eq("binary data")
      end
    end

    context "with missing content_type" do
      it "defaults to passthrough when content_type is nil" do
        result = decorator.call(body: "some data", content_type: nil)
        expect(result).to eq("some data")
      end
    end

    context "with non-hash input" do
      it "converts to string for non-hash results" do
        result = decorator.call("plain string")
        expect(result).to eq("plain string")
      end
    end

    context "with whitespace collapsing" do
      it "collapses excessive blank lines in HTML conversion" do
        html = "<p>first</p>\n\n\n\n\n<p>second</p>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).not_to match(/\n{3,}/)
      end
    end
  end

  describe "#decorate" do
    it "dispatches application/json to application_json" do
      result = decorator.decorate('{"a":1}', content_type: "application/json")
      expect(result[:meta]).to eq("[Converted: JSON → TOON]")
    end

    it "dispatches text/html to text_html" do
      result = decorator.decorate("<b>hi</b>", content_type: "text/html")
      expect(result[:meta]).to eq("[Converted: HTML → Markdown]")
    end

    it "dispatches unknown types to method_missing passthrough" do
      result = decorator.decorate("data", content_type: "application/octet-stream")
      expect(result[:meta]).to be_nil
      expect(result[:text]).to eq("data")
    end

    it "strips Content-Type parameters before dispatching" do
      result = decorator.decorate('{"a":1}', content_type: "application/json; charset=utf-8")
      expect(result[:meta]).to eq("[Converted: JSON → TOON]")
    end
  end
end
