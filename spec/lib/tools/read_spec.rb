# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Read do
  subject(:tool) { described_class.new }

  let(:tmpdir) { Dir.mktmpdir("tools-read-spec") }

  after { FileUtils.remove_entry(tmpdir) }

  describe ".tool_name" do
    it "returns read" do
      expect(described_class.tool_name).to eq("read")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".input_schema" do
    it "defines path as a required string property" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:path][:type]).to eq("string")
      expect(schema[:required]).to include("path")
    end

    it "defines offset and limit as optional integer properties" do
      schema = described_class.input_schema
      expect(schema[:properties][:offset][:type]).to eq("integer")
      expect(schema[:properties][:limit][:type]).to eq("integer")
      expect(schema[:required]).not_to include("offset", "limit")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "read", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    def write_file(name, content)
      path = File.join(tmpdir, name)
      File.write(path, content)
      path
    end

    context "with a basic file" do
      it "returns file contents as plain text" do
        path = write_file("hello.txt", "Hello, world!\nSecond line\n")

        result = tool.execute("path" => path)

        expect(result).to eq("Hello, world!\nSecond line\n")
      end

      it "returns empty string for empty files" do
        path = write_file("empty.txt", "")

        result = tool.execute("path" => path)

        expect(result).to eq("")
      end
    end

    context "with CRLF line endings" do
      it "normalizes CRLF to LF" do
        path = write_file("windows.txt", "line one\r\nline two\r\n")

        result = tool.execute("path" => path)

        expect(result).to eq("line one\nline two\n")
        expect(result).not_to include("\r")
      end
    end

    context "with offset and limit" do
      let(:path) do
        content = (1..10).map { |i| "Line #{i}\n" }.join
        write_file("numbered.txt", content)
      end

      it "reads from the specified offset" do
        result = tool.execute("path" => path, "offset" => 3)

        expect(result).to start_with("Line 3\n")
        expect(result.lines.first).to eq("Line 3\n")
      end

      it "limits the number of lines returned" do
        result = tool.execute("path" => path, "limit" => 3)

        expect(result).to include("Line 1\nLine 2\nLine 3\n")
        expect(result).to include("[Showing lines 1-3 of 10. Use offset=4 to continue.]")
      end

      it "combines offset and limit" do
        result = tool.execute("path" => path, "offset" => 4, "limit" => 2)

        expect(result).to include("Line 4\nLine 5\n")
        expect(result).to include("[Showing lines 4-5 of 10. Use offset=6 to continue.]")
      end

      it "returns hint when offset is beyond end of file" do
        result = tool.execute("path" => path, "offset" => 100)

        expect(result).to include("10 lines")
        expect(result).to include("beyond end of file")
      end

      it "clamps offset to minimum of 1" do
        result = tool.execute("path" => path, "offset" => -5)

        expect(result).to start_with("Line 1\n")
      end

      it "clamps limit to minimum of 1" do
        result = tool.execute("path" => path, "limit" => 0)

        lines = result.lines.reject { |l| l.start_with?("\n\n[") }
        expect(lines.first).to eq("Line 1\n")
      end
    end

    context "with line count truncation" do
      it "truncates at max_read_lines and appends continuation hint" do
        content = (1..3000).map { |i| "Line #{i}\n" }.join
        path = write_file("large.txt", content)

        result = tool.execute("path" => path)

        expect(result).to include("[Showing lines 1-2000 of 3000. Use offset=2001 to continue.]")
        expect(result).not_to include("Line 2001\n")
      end

      it "does not truncate when exactly at max_read_lines" do
        content = (1..2000).map { |i| "Line #{i}\n" }.join
        path = write_file("exact.txt", content)

        result = tool.execute("path" => path)

        expect(result).not_to include("[Showing lines")
        expect(result).to include("Line 2000\n")
      end
    end

    context "with byte size truncation" do
      it "truncates when accumulated bytes exceed max_read_bytes" do
        # Each line is ~1000 bytes, 60 lines = 60KB > 50KB limit
        content = (1..60).map { |i| "L#{i}#{"x" * 998}\n" }.join
        path = write_file("big_lines.txt", content)

        result = tool.execute("path" => path)

        expect(result).to include("[Showing lines")
        expect(result).to include("Use offset=")
        expect(result.bytesize).to be < Anima::Settings.max_read_bytes * 2
      end
    end

    context "with a single line exceeding max_read_bytes" do
      it "returns an error suggesting bash" do
        content = "x" * (Anima::Settings.max_read_bytes + 1)
        path = write_file("minified.js", content)

        result = tool.execute("path" => path)

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("exceeds #{Anima::Settings.max_read_bytes} bytes")
        expect(result[:error]).to include("bash tool")
        expect(result[:error]).to include("sed")
      end
    end

    context "with a file exceeding max_file_size" do
      it "returns an error suggesting bash" do
        path = write_file("huge.log", "x")
        allow(File).to receive(:size).with(path).and_return(Anima::Settings.max_file_size + 1)

        result = tool.execute("path" => path)

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Max readable size")
        expect(result[:error]).to include("bash tool")
      end
    end

    context "with error conditions" do
      it "returns error for blank path" do
        result = tool.execute("path" => "  ")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("blank")
      end

      it "returns error for nonexistent file" do
        result = tool.execute("path" => "/nonexistent/path/file.txt")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("File not found")
      end

      it "returns error for directories" do
        result = tool.execute("path" => tmpdir)

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Is a directory")
      end

      it "returns error for unreadable files" do
        path = write_file("secret.txt", "classified")
        File.chmod(0o000, path)

        result = tool.execute("path" => path)

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Permission denied")
      ensure
        File.chmod(0o644, path)
      end
    end

    context "with relative path resolution" do
      it "resolves relative paths against working directory" do
        write_file("relative.txt", "found it\n")
        tool_with_wd = described_class.new(shell_session: double(pwd: tmpdir))

        result = tool_with_wd.execute("path" => "relative.txt")

        expect(result).to eq("found it\n")
      end

      it "resolves relative paths against process directory without shell session" do
        path = write_file("absolute.txt", "absolute content\n")

        result = tool.execute("path" => path)

        expect(result).to eq("absolute content\n")
      end
    end

    context "with continuation hint format" do
      it "includes correct next offset in continuation hint" do
        content = (1..100).map { |i| "Line #{i}\n" }.join
        path = write_file("paging.txt", content)

        result = tool.execute("path" => path, "offset" => 10, "limit" => 5)

        expect(result).to include("[Showing lines 10-14 of 100. Use offset=15 to continue.]")
      end

      it "does not include hint when all remaining lines fit" do
        content = (1..10).map { |i| "Line #{i}\n" }.join
        path = write_file("short.txt", content)

        result = tool.execute("path" => path, "offset" => 8)

        expect(result).not_to include("[Showing lines")
        expect(result).to include("Line 8\n")
        expect(result).to include("Line 10\n")
      end
    end
  end
end
