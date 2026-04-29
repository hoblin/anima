# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Write do
  subject(:tool) { described_class.new }

  let(:tmpdir) { Dir.mktmpdir("tools-write-spec") }

  after { FileUtils.remove_entry(tmpdir) }

  describe ".tool_name" do
    it "returns write_file" do
      expect(described_class.tool_name).to eq("write_file")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".prompt_snippet" do
    it "advertises write_file in the system prompt menu" do
      expect(described_class.prompt_snippet).to eq("Create or overwrite a whole file.")
    end
  end

  describe ".prompt_guidelines" do
    it "steers the agent toward edit_file for targeted changes" do
      expect(described_class.prompt_guidelines).to include(a_string_matching(/replaces the whole file.*use edit_file/))
    end
  end

  describe ".input_schema" do
    it "defines path and content as required string properties" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:path][:type]).to eq("string")
      expect(schema[:properties][:content][:type]).to eq("string")
      expect(schema[:required]).to contain_exactly("path", "content")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "write_file", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    context "with a new file" do
      it "creates the file and returns bytes written" do
        path = File.join(tmpdir, "new.txt")

        result = tool.execute("path" => path, "content" => "Hello, world!\n")

        expect(result).to eq("Wrote 14 bytes to #{path}")
        expect(File.read(path)).to eq("Hello, world!\n")
      end

      it "creates a file with empty content" do
        path = File.join(tmpdir, "empty.txt")

        result = tool.execute("path" => path, "content" => "")

        expect(result).to eq("Wrote 0 bytes to #{path}")
        expect(File.read(path)).to eq("")
      end
    end

    context "when overwriting an existing file" do
      it "replaces file contents entirely" do
        path = File.join(tmpdir, "existing.txt")
        File.write(path, "old content\n")

        result = tool.execute("path" => path, "content" => "new content\n")

        expect(result).to eq("Wrote 12 bytes to #{path}")
        expect(File.read(path)).to eq("new content\n")
      end
    end

    context "with intermediate directory creation" do
      it "creates parent directories recursively" do
        path = File.join(tmpdir, "a", "b", "c", "deep.txt")

        result = tool.execute("path" => path, "content" => "deep\n")

        expect(result).to eq("Wrote 5 bytes to #{path}")
        expect(File.read(path)).to eq("deep\n")
      end
    end

    context "with error conditions" do
      it "returns error for blank path" do
        result = tool.execute("path" => "  ", "content" => "data")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("blank")
      end

      it "returns error when path is a directory" do
        result = tool.execute("path" => tmpdir, "content" => "data")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Is a directory")
      end

      it "returns error for unwritable existing file" do
        path = File.join(tmpdir, "readonly.txt")
        File.write(path, "locked")
        File.chmod(0o444, path)

        result = tool.execute("path" => path, "content" => "overwrite")

        expect(result).to eq({error: "Not writable: #{path}"})
        expect(File.read(path)).to eq("locked")
      ensure
        File.chmod(0o644, path)
      end
    end

    context "with filesystem errors during write" do
      it "returns error when disk is full" do
        path = File.join(tmpdir, "full.txt")
        allow(File).to receive(:write).with(path, "data").and_raise(Errno::ENOSPC)

        result = tool.execute("path" => path, "content" => "data")

        expect(result).to eq({error: "No space left on device: #{path}"})
      end

      it "returns error on read-only file system" do
        path = File.join(tmpdir, "rofs.txt")
        allow(File).to receive(:write).with(path, "data").and_raise(Errno::EROFS)

        result = tool.execute("path" => path, "content" => "data")

        expect(result).to eq({error: "Read-only file system: #{path}"})
      end

      it "returns error when directory creation is denied" do
        path = File.join(tmpdir, "denied", "file.txt")
        allow(FileUtils).to receive(:mkdir_p).and_raise(Errno::EACCES)

        result = tool.execute("path" => path, "content" => "data")

        expect(result).to eq({error: "Permission denied: #{path}"})
      end
    end

    context "with relative path resolution" do
      it "resolves relative paths against working directory" do
        tool_with_wd = described_class.new(shell_session: double(pwd: tmpdir))
        expected_path = File.join(tmpdir, "relative.txt")

        result = tool_with_wd.execute("path" => "relative.txt", "content" => "resolved\n")

        expect(result).to eq("Wrote 9 bytes to #{expected_path}")
        expect(File.read(expected_path)).to eq("resolved\n")
      end

      it "resolves relative paths against process directory without shell session" do
        path = File.join(tmpdir, "absolute.txt")

        result = tool.execute("path" => path, "content" => "absolute\n")

        expect(result).to eq("Wrote 9 bytes to #{path}")
        expect(File.read(path)).to eq("absolute\n")
      end
    end

    context "with content passthrough" do
      it "preserves CRLF line endings" do
        path = File.join(tmpdir, "windows.txt")

        tool.execute("path" => path, "content" => "line one\r\nline two\r\n")

        expect(File.binread(path)).to eq("line one\r\nline two\r\n")
      end

      it "preserves UTF-8 multibyte characters" do
        path = File.join(tmpdir, "unicode.txt")

        tool.execute("path" => path, "content" => "Hello \u{1F30D}\n")

        expect(File.read(path)).to eq("Hello \u{1F30D}\n")
      end
    end
  end
end
