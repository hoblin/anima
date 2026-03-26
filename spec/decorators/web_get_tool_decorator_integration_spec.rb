# frozen_string_literal: true

require "rails_helper"

# Integration tests for the full WebGet → WebGetToolDecorator pipeline
# against real-world pages. VCR cassettes capture the actual HTML served
# by each site, ensuring the converter handles real page structures.
RSpec.describe WebGetToolDecorator, "real-world pages" do
  subject(:decorator) { described_class.new }

  let(:tool) { Tools::WebGet.new }

  # Fetches a URL and decorates the result through the full pipeline.
  def fetch_and_convert(url)
    raw = tool.execute("url" => url)
    expect(raw).not_to have_key(:error), "WebGet failed for #{url}: #{raw[:error]}"
    decorator.call(raw)
  end

  describe "GitHub pages" do
    context "with an issue list", :vcr do
      it "extracts issue titles" do
        result = fetch_and_convert("https://github.com/hoblin/anima/issues")

        expect(result).to include("HTML-to-Markdown converter returns empty content on GitHub pages")
      end
    end

    context "with a single issue", :vcr do
      it "extracts the issue body content" do
        result = fetch_and_convert("https://github.com/hoblin/anima/issues/316")

        expect(result).to include("Which page structures produce empty or near-empty output?")
        expect(result).to include("the agent fetched")
      end
    end

    context "with a repo root", :vcr do
      it "extracts the repo name and file tree" do
        result = fetch_and_convert("https://github.com/hoblin/anima")

        expect(result).to include("hoblin/anima")
        expect(result).to include("Folders and files")
      end
    end
  end

  describe "Stack Overflow" do
    context "with a question page", :vcr do
      it "extracts question and answer content" do
        result = fetch_and_convert(
          "https://stackoverflow.com/questions/11227809/why-is-processing-a-sorted-array-faster-than-processing-an-unsorted-array"
        )

        expect(result).to include("sorting the data")
        expect(result).to include("What is Branch Prediction?")
      end
    end
  end

  describe "Ruby docs" do
    context "with a class documentation page", :vcr do
      it "extracts class description and method examples" do
        result = fetch_and_convert("https://ruby-doc.org/3.3.7/String.html")

        expect(result).to include("arbitrary sequence of bytes")
        expect(result).to include("delete_prefix")
      end
    end
  end

  describe "MDN Web Docs" do
    context "with an HTML element reference page", :vcr do
      it "extracts element description and technical details" do
        result = fetch_and_convert("https://developer.mozilla.org/en-US/docs/Web/HTML/Reference/Elements/main")

        expect(result).to include("central topic of a document")
        expect(result).to include("both the starting and ending tags are mandatory")
      end
    end
  end

  describe "static blog" do
    context "with a Coding Horror post", :vcr do
      it "extracts article quotes and body text" do
        result = fetch_and_convert("https://blog.codinghorror.com/the-first-rule-of-programming-its-always-your-fault/")

        expect(result).to include("the bug exists in the application code under development")
        expect(result).to include("95% are caused by programmers")
      end
    end
  end
end
