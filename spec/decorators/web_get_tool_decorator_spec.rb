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

      it "strips nav elements when no semantic container exists" do
        result = decorator.call(body: html, content_type: "text/html")
        expect(result).not_to include("Home")
      end

      it "strips footer elements when no semantic container exists" do
        result = decorator.call(body: html, content_type: "text/html")
        expect(result).not_to include("Copyright")
      end

      it "strips noscript tags" do
        noscript_html = "<html><body><noscript><p>Enable JavaScript</p></noscript><p>Content here is visible and real.</p></body></html>"
        result = decorator.call(body: noscript_html, content_type: "text/html")

        expect(result).not_to include("Enable JavaScript")
        expect(result).to include("Content here")
      end

      it "strips iframe tags" do
        iframe_html = "<html><body><iframe src='https://example.com'><p>Fallback text</p></iframe><p>Visible page content for testing purposes.</p></body></html>"
        result = decorator.call(body: iframe_html, content_type: "text/html")

        expect(result).not_to include("Fallback text")
        expect(result).to include("Visible page content")
      end

      it "strips svg tags" do
        svg_html = "<html><body><svg><circle cx='50' cy='50' r='40'/></svg><p>Real text content that should be extracted properly.</p></body></html>"
        result = decorator.call(body: svg_html, content_type: "text/html")

        expect(result).not_to include("circle")
        expect(result).to include("Real text content")
      end

      it "strips form elements when no semantic container exists" do
        form_html = "<html><body><form><input type='text'/><p>Form label</p></form><p>Page content that is long enough to avoid the short content warning flag.</p></body></html>"
        result = decorator.call(body: form_html, content_type: "text/html")

        expect(result).not_to include("Form label")
        expect(result).to include("Page content")
      end

      it "strips menu elements when no semantic container exists" do
        menu_html = "<html><body><menu><li>Option A</li></menu><menuitem>Hidden item</menuitem><p>Main page content that exceeds the minimum character threshold easily.</p></body></html>"
        result = decorator.call(body: menu_html, content_type: "text/html")

        expect(result).not_to include("Option A")
        expect(result).to include("Main page content")
      end

      it "handles Content-Type with charset parameter" do
        result = decorator.call(body: html, content_type: "text/html; charset=utf-8")
        expect(result).to start_with("[Converted: HTML → Markdown]")
      end
    end

    context "with HTML containing a <main> element" do
      let(:html) do
        <<~HTML
          <html><body>
            <header><nav>Site Nav</nav></header>
            <main>
              <h1>Primary Content</h1>
              <p>This is the main article text with enough length to pass the threshold easily.</p>
              <nav aria-label="pagination"><a href="/page/2">Next</a></nav>
            </main>
            <footer>Footer links</footer>
          </body></html>
        HTML
      end

      it "extracts content from <main> instead of stripping noise" do
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("Primary Content")
        expect(result).to include("main article text")
      end

      it "preserves nav elements inside <main>" do
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("Next")
      end

      it "excludes content outside <main>" do
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).not_to include("Site Nav")
        expect(result).not_to include("Footer links")
      end
    end

    context "with HTML containing an <article> element" do
      let(:html) do
        <<~HTML
          <html><body>
            <nav>Navigation</nav>
            <article>
              <h2>Blog Post Title</h2>
              <p>Article body with enough content to be meaningful for reading and extraction.</p>
            </article>
            <aside>Sidebar</aside>
          </body></html>
        HTML
      end

      it "extracts content from <article>" do
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("Blog Post Title")
        expect(result).to include("Article body")
      end

      it "excludes nav and aside outside <article>" do
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).not_to include("Navigation")
        expect(result).not_to include("Sidebar")
      end
    end

    context "with HTML containing role='main'" do
      it "extracts content from the role='main' element" do
        html = <<~HTML
          <html><body>
            <header>Header</header>
            <div role="main">
              <h1>Accessible Content</h1>
              <p>This page uses ARIA role instead of the semantic main element for its content.</p>
            </div>
            <footer>Footer</footer>
          </body></html>
        HTML

        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("Accessible Content")
        expect(result).not_to include("Header")
        expect(result).not_to include("Footer")
      end
    end

    context "when content exists only in structural noise tags" do
      it "warns when no semantic container and noise removal leaves little content" do
        html = <<~HTML
          <html><body>
            <nav>
              <h1>Issues</h1>
              <ul><li>Bug #1: Fix the widget so it renders properly in production.</li></ul>
            </nav>
          </body></html>
        HTML

        result = decorator.call(body: html, content_type: "text/html")

        # No semantic container → falls back to noise removal → content lost
        # This is expected behavior; the warning flag signals the problem
        expect(result).to include("[Warning:")
      end
    end

    context "with short content warning" do
      it "warns when extracted content is below threshold" do
        html = "<html><body><p>Short</p></body></html>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("[Warning:")
        expect(result).to include("content may be incomplete")
      end

      it "warns at one below threshold (99 chars)" do
        html = "<html><body><p>#{"x" * 99}</p></body></html>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("[Warning:")
      end

      it "does not warn at exactly the threshold (100 chars)" do
        html = "<html><body><p>#{"x" * 100}</p></body></html>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).not_to include("[Warning:")
      end

      it "does not warn when content is above threshold" do
        html = "<html><body><p>#{"x" * 200}</p></body></html>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).not_to include("[Warning:")
      end

      it "does not warn on empty body" do
        result = decorator.call(body: "", content_type: "text/html")

        expect(result).not_to include("[Warning:")
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

    context "with HTML without body tag" do
      it "falls back to full document content" do
        html = "<h1>No Body</h1><p>Just a fragment</p>"
        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to start_with("[Converted: HTML → Markdown]")
        expect(result).to include("# No Body")
        expect(result).to include("Just a fragment")
      end
    end

    context "with empty body" do
      it "returns metadata tag for empty HTML" do
        result = decorator.call(body: "", content_type: "text/html")

        expect(result).to start_with("[Converted: HTML → Markdown]")
      end

      it "returns empty string for empty plain text" do
        result = decorator.call(body: "", content_type: "text/plain")
        expect(result).to eq("")
      end

      it "passes through empty JSON as-is" do
        result = decorator.call(body: "", content_type: "application/json")
        expect(result).to eq("")
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

    context "with <main> preferred over <article>" do
      it "uses <main> when both exist" do
        html = <<~HTML
          <html><body>
            <article><p>Article content that should be ignored when main is present.</p></article>
            <main><p>Main content is the primary extraction target for the converter.</p></main>
          </body></html>
        HTML

        result = decorator.call(body: html, content_type: "text/html")

        expect(result).to include("Main content")
        expect(result).not_to include("Article content")
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
      expect(result[:meta]).to start_with("[Converted: HTML → Markdown]")
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
