# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::Edit do
  subject(:tool) { described_class.new }

  let(:tmpdir) { Dir.mktmpdir("tools-edit-spec") }

  after { FileUtils.remove_entry(tmpdir) }

  def write_file(name, content, mode: "w")
    path = File.join(tmpdir, name)
    File.write(path, content, mode: mode)
    path
  end

  describe ".tool_name" do
    it "returns edit_file" do
      expect(described_class.tool_name).to eq("edit_file")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).not_to be_empty
    end
  end

  describe ".prompt_snippet" do
    it "advertises edit_file in the system prompt menu" do
      expect(described_class.prompt_snippet).to eq("Replace exact text in a file.")
    end
  end

  describe ".prompt_guidelines" do
    it "contributes nothing — guideline text is deferred to a follow-up ticket" do
      expect(described_class.prompt_guidelines).to eq([])
    end
  end

  describe ".input_schema" do
    it "defines path, old_text, and new_text as required string properties" do
      schema = described_class.input_schema
      expect(schema[:type]).to eq("object")
      expect(schema[:properties][:path][:type]).to eq("string")
      expect(schema[:properties][:old_text][:type]).to eq("string")
      expect(schema[:properties][:new_text][:type]).to eq("string")
      expect(schema[:required]).to contain_exactly("path", "old_text", "new_text")
    end
  end

  describe ".schema" do
    it "builds valid Anthropic tool schema" do
      schema = described_class.schema
      expect(schema).to include(name: "edit_file", description: a_kind_of(String))
      expect(schema[:input_schema]).to be_a(Hash)
    end
  end

  describe "#execute" do
    context "with exact match" do
      it "replaces a single line and returns a diff" do
        path = write_file("single.rb", "def greet\n  'hi'\nend\n")

        result = tool.execute("path" => path, "old_text" => "  'hi'", "new_text" => "  'hello'")

        expect(result).to include("--- #{path}")
        expect(result).to include("-  'hi'")
        expect(result).to include("+  'hello'")
        expect(File.read(path)).to eq("def greet\n  'hello'\nend\n")
      end

      it "replaces multiple lines" do
        path = write_file("multi.rb", "class Foo\n  def bar\n    1\n  end\nend\n")

        result = tool.execute(
          "path" => path,
          "old_text" => "  def bar\n    1\n  end",
          "new_text" => "  def bar\n    2\n  end"
        )

        expect(result).to include("-    1")
        expect(result).to include("+    2")
        expect(File.read(path)).to eq("class Foo\n  def bar\n    2\n  end\nend\n")
      end

      it "deletes text when new_text is empty" do
        path = write_file("delete.txt", "keep\nremove\nkeep\n")

        result = tool.execute("path" => path, "old_text" => "remove\n", "new_text" => "")

        expect(result).to include("-remove")
        expect(File.read(path)).to eq("keep\nkeep\n")
      end
    end

    context "with uniqueness constraint" do
      it "returns error when old_text matches zero locations" do
        path = write_file("nope.txt", "hello world\n")

        result = tool.execute("path" => path, "old_text" => "missing text", "new_text" => "x")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Could not find old_text")
        expect(result[:error]).to include("read_file tool")
      end

      it "returns error with line numbers when old_text matches multiple locations" do
        path = write_file("dupes.txt", "foo\nbar\nfoo\n")

        result = tool.execute("path" => path, "old_text" => "foo", "new_text" => "baz")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("2 matches")
        expect(result[:error]).to include("lines: 1, 3")
      end
    end

    context "with fuzzy matching" do
      it "matches tabs against spaces" do
        path = write_file("tabs.rb", "def foo\n\tbar\nend\n")

        result = tool.execute(
          "path" => path,
          "old_text" => "def foo\n  bar\nend\n",
          "new_text" => "def foo\n\tbaz\nend\n"
        )

        expect(result).to include("fuzzy match")
        expect(File.read(path)).to eq("def foo\n\tbaz\nend\n")
      end

      it "matches despite extra inline whitespace" do
        path = write_file("spaces.txt", "x  +  y\n")

        result = tool.execute(
          "path" => path,
          "old_text" => "x + y\n",
          "new_text" => "x + z\n"
        )

        expect(result).to include("fuzzy match")
        expect(File.read(path)).to eq("x + z\n")
      end

      it "returns error with line numbers when multiple fuzzy matches exist" do
        path = write_file("fuzzy_dupes.rb", "\tbar\nbaz\n\t\tbar\n")

        result = tool.execute("path" => path, "old_text" => "  bar", "new_text" => "  qux")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("fuzzy matches")
        expect(result[:error]).to include("lines:")
      end
    end

    context "with no-op detection" do
      it "returns error when old_text and new_text are identical" do
        path = write_file("noop.txt", "unchanged\n")

        result = tool.execute("path" => path, "old_text" => "unchanged", "new_text" => "unchanged")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("identical")
      end
    end

    context "with BOM handling" do
      it "strips BOM for matching and restores it after edit" do
        bom = "\xEF\xBB\xBF"
        path = File.join(tmpdir, "bom.txt")
        File.binwrite(path, "#{bom}hello world\n")

        result = tool.execute("path" => path, "old_text" => "hello", "new_text" => "goodbye")

        expect(result).to include("-hello world")
        expect(result).to include("+goodbye world")
        raw = File.binread(path)
        expect(raw.b[0, 3]).to eq(bom.b)
        expect(raw[3..].force_encoding("UTF-8")).to eq("goodbye world\n")
      end
    end

    context "with CRLF handling" do
      it "normalizes CRLF for matching and restores after edit" do
        path = File.join(tmpdir, "crlf.txt")
        File.binwrite(path, "line one\r\nline two\r\nline three\r\n")

        result = tool.execute("path" => path, "old_text" => "line two", "new_text" => "line TWO")

        expect(result).to include("-line two")
        expect(result).to include("+line TWO")
        raw = File.binread(path)
        expect(raw).to eq("line one\r\nline TWO\r\nline three\r\n")
      end
    end

    context "with validation errors" do
      it "returns error for blank path" do
        result = tool.execute("path" => "  ", "old_text" => "x", "new_text" => "y")

        expect(result).to eq({error: "Path cannot be blank"})
      end

      it "returns error for blank old_text" do
        path = write_file("blank.txt", "data\n")

        result = tool.execute("path" => path, "old_text" => "", "new_text" => "y")

        expect(result).to eq({error: "old_text cannot be blank"})
      end

      it "returns error for nonexistent file" do
        result = tool.execute("path" => "/nonexistent/file.txt", "old_text" => "x", "new_text" => "y")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("File not found")
      end

      it "returns error when path is a directory" do
        result = tool.execute("path" => tmpdir, "old_text" => "x", "new_text" => "y")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Is a directory")
      end

      it "returns error for unwritable file" do
        path = write_file("locked.txt", "data\n")
        File.chmod(0o444, path)

        result = tool.execute("path" => path, "old_text" => "data", "new_text" => "new")

        expect(result).to eq({error: "Permission denied: #{path}"})
      ensure
        File.chmod(0o644, path)
      end

      it "returns error for file exceeding size limit" do
        path = write_file("big.txt", "data\n")
        allow(File).to receive(:size).with(path).and_return(Anima::Settings.max_file_size + 1)

        result = tool.execute("path" => path, "old_text" => "data", "new_text" => "new")

        expect(result).to be_a(Hash)
        expect(result[:error]).to include("Max editable size")
      end
    end

    context "with filesystem errors during write" do
      it "returns error when disk is full" do
        path = write_file("full.txt", "old\n")
        allow(File).to receive(:binwrite).and_raise(Errno::ENOSPC)

        result = tool.execute("path" => path, "old_text" => "old", "new_text" => "new")

        expect(result).to eq({error: "No space left on device: #{path}"})
      end

      it "returns error on read-only file system" do
        path = write_file("rofs.txt", "old\n")
        allow(File).to receive(:binwrite).and_raise(Errno::EROFS)

        result = tool.execute("path" => path, "old_text" => "old", "new_text" => "new")

        expect(result).to eq({error: "Read-only file system: #{path}"})
      end

      it "returns error when write permission is denied at OS level" do
        path = write_file("denied.txt", "old\n")
        allow(File).to receive(:binwrite).and_raise(Errno::EACCES)

        result = tool.execute("path" => path, "old_text" => "old", "new_text" => "new")

        expect(result).to eq({error: "Permission denied: #{path}"})
      end
    end

    context "with relative path resolution" do
      it "resolves relative paths against working directory" do
        write_file("rel.txt", "before\n")
        tool_with_wd = described_class.new(shell_session: double(pwd: tmpdir))

        result = tool_with_wd.execute("path" => "rel.txt", "old_text" => "before", "new_text" => "after")

        expect(result).to include("-before")
        expect(result).to include("+after")
        expect(File.read(File.join(tmpdir, "rel.txt"))).to eq("after\n")
      end
    end

    context "with diff output format" do
      it "includes context lines around the change" do
        content = (1..10).map { |i| "line #{i}\n" }.join
        path = write_file("ctx.txt", content)

        result = tool.execute("path" => path, "old_text" => "line 5", "new_text" => "LINE FIVE")

        expect(result).to include("--- #{path}")
        expect(result).to include("+++ #{path}")
        expect(result).to include("@@")
        expect(result).to include(" line 4")
        expect(result).to include("-line 5")
        expect(result).to include("+LINE FIVE")
        expect(result).to include(" line 6")
      end
    end
  end
end
