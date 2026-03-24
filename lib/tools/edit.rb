# frozen_string_literal: true

module Tools
  # Performs surgical text replacement with uniqueness constraint.
  # Finds old_text in the file (must match exactly one location), replaces
  # with new_text, and returns a unified diff. Falls back to
  # whitespace-normalized fuzzy matching when exact match fails.
  #
  # Normalizes BOM and CRLF line endings for matching, restoring them after
  # the edit. Rejects ambiguous edits where old_text matches zero or
  # multiple locations.
  #
  # @example Replacing a method body
  #   tool.execute("path" => "app.rb",
  #                "old_text" => "def greet\n  'hi'\nend",
  #                "new_text" => "def greet\n  'hello'\nend")
  #   # => "--- app.rb\n+++ app.rb\n@@ -1,3 +1,3 @@\n ..."
  class Edit < Base
    def self.tool_name = "edit"

    def self.description = "Replace text in a file."

    def self.input_schema
      {
        type: "object",
        properties: {
          path: {type: "string", description: "Relative paths resolve against working directory."},
          old_text: {type: "string", description: "Must match exactly one location. Include surrounding lines for uniqueness."},
          new_text: {type: "string", description: "Empty string to delete."}
        },
        required: %w[path old_text new_text]
      }
    end

    # @param shell_session [ShellSession, nil] provides working directory for resolving relative paths
    def initialize(shell_session: nil, **)
      @working_directory = shell_session&.pwd
    end

    # @param input [Hash<String, Object>] string-keyed hash from the Anthropic API
    # @return [String] unified diff showing the change
    # @return [Hash] with :error key on failure
    def execute(input)
      path, old_text, new_text = extract_params(input)
      return {error: "Path cannot be blank"} if path.empty?
      return {error: "old_text cannot be blank"} if old_text.empty?

      path = resolve_path(path)

      error = validate_file(path)
      return error if error

      edit_file(path, old_text, new_text)
    end

    private

    def extract_params(input)
      path = input["path"].to_s.strip
      old_text = input["old_text"].to_s
      new_text = input["new_text"].to_s
      [path, old_text, new_text]
    end

    def resolve_path(path)
      if @working_directory
        File.expand_path(path, @working_directory)
      else
        File.expand_path(path)
      end
    end

    def validate_file(path)
      return {error: "File not found: #{path}"} unless File.exist?(path)
      return {error: "Is a directory: #{path}"} if File.directory?(path)
      return {error: "Permission denied: #{path}"} unless File.readable?(path) && File.writable?(path)
      size = File.size(path)
      max_size = Anima::Settings.max_file_size
      if size > max_size
        {error: "File is #{size} bytes (#{size / 1_048_576} MB). " \
                "Max editable size is #{max_size / 1_048_576} MB. Use bash tool with sed instead."}
      end
    end

    def edit_file(path, old_text, new_text)
      raw = File.binread(path)
      bom = extract_bom(raw)
      content = raw[bom.length..].force_encoding("UTF-8")
      had_crlf = content.include?("\r\n")
      normalized = had_crlf ? content.gsub("\r\n", "\n") : content

      match = find_unique_match(normalized, old_text, path)
      return match if match.is_a?(Hash)

      position, matched_text, fuzzy = match
      new_content = normalized[0...position] + new_text + normalized[(position + matched_text.length)..]

      if normalized == new_content
        return {error: "old_text and new_text are identical. No changes made to #{path}."}
      end

      output = had_crlf ? new_content.gsub("\n", "\r\n") : new_content
      File.binwrite(path, bom + output.b)

      build_diff(path, normalized, new_content, fuzzy)
    rescue Errno::EACCES
      {error: "Permission denied: #{path}"}
    rescue Errno::ENOSPC
      {error: "No space left on device: #{path}"}
    rescue Errno::EROFS
      {error: "Read-only file system: #{path}"}
    end

    # @return [String] UTF-8 BOM bytes if present, empty binary string otherwise
    def extract_bom(raw)
      bytes = raw.b
      bytes.start_with?("\xEF\xBB\xBF".b) ? bytes[0, 3] : "".b
    end

    # Finds exactly one match for old_text in content.
    # Tries exact match first, then whitespace-normalized fuzzy match.
    # @return [Array(Integer, String, Boolean)] position, matched text, fuzzy flag
    # @return [Hash] error hash if zero or multiple matches found
    def find_unique_match(content, old_text, path)
      exact = find_all_positions(content, old_text)
      return [exact[0], old_text, false] if exact.one?
      return ambiguity_error(exact, content, path) if exact.length > 1

      fuzzy = find_fuzzy_matches(content, old_text)
      return [fuzzy[0][0], fuzzy[0][1], true] if fuzzy.one?
      return ambiguity_error(fuzzy.map(&:first), content, path, fuzzy: true) if fuzzy.length > 1

      {error: "Could not find old_text in #{path}. " \
              "Verify the text exists and matches exactly (including whitespace). " \
              "Use the read tool to check current file contents."}
    end

    def ambiguity_error(positions, content, path, fuzzy: false)
      kind = fuzzy ? "fuzzy matches" : "matches"
      line_numbers = positions.map { |pos| line_number_at(content, pos) }
      {error: "Found #{positions.length} #{kind} for old_text in #{path}. " \
              "Provide more surrounding context to uniquely identify the location. " \
              "Matches at lines: #{line_numbers.join(", ")}"}
    end

    def line_number_at(content, position)
      content[0...position].count("\n") + 1
    end

    def find_all_positions(content, text)
      positions = []
      offset = 0
      while (pos = content.index(text, offset))
        positions << pos
        offset = pos + 1
      end
      positions
    end

    # Finds old_text in content using whitespace-normalized line comparison.
    # @return [Array<Array(Integer, String)>] array of [position, matched_text] pairs
    def find_fuzzy_matches(content, old_text)
      content_lines = content.split("\n", -1)
      search_lines = old_text.split("\n", -1)
      search_lines.pop if search_lines.last&.empty? && old_text.end_with?("\n")
      trailing_newline = old_text.end_with?("\n")

      normalized_search = search_lines.map { |line| collapse_whitespace(line) }
      return [] if normalized_search.all?(&:empty?)

      window_size = search_lines.length
      matches = []
      (0..content_lines.length - window_size).each do |start_idx|
        window = content_lines[start_idx, window_size]
        next unless window.map { |line| collapse_whitespace(line) } == normalized_search

        pos = start_idx.zero? ? 0 : content_lines[0...start_idx].sum { |line| line.length + 1 }
        matched = window.join("\n")
        matched += "\n" if trailing_newline
        matches << [pos, matched]
      end

      matches
    end

    def collapse_whitespace(text)
      text.gsub(/[[:blank:]]+/, " ").strip
    end

    # Generates a unified diff between old and new content with 3 lines of context.
    DIFF_CONTEXT = 3

    def build_diff(path, old_content, new_content, fuzzy)
      before = old_content.lines(chomp: true)
      after = new_content.lines(chomp: true)

      first = 0
      first += 1 while first < before.length && first < after.length && before[first] == after[first]

      old_end = before.length - 1
      new_end = after.length - 1
      while old_end > first && new_end > first && before[old_end] == after[new_end]
        old_end -= 1
        new_end -= 1
      end

      ctx_start = [first - DIFF_CONTEXT, 0].max
      old_ctx_end = [old_end + DIFF_CONTEXT, before.length - 1].min
      new_ctx_end = [new_end + DIFF_CONTEXT, after.length - 1].min

      hunk = []
      hunk << "--- #{path}"
      hunk << "+++ #{path}"
      hunk << "@@ -#{ctx_start + 1},#{old_ctx_end - ctx_start + 1} +#{ctx_start + 1},#{new_ctx_end - ctx_start + 1} @@"
      (ctx_start...first).each { |idx| hunk << " #{before[idx]}" }
      (first..old_end).each { |idx| hunk << "-#{before[idx]}" }
      (first..new_end).each { |idx| hunk << "+#{after[idx]}" }
      ((old_end + 1)..old_ctx_end).each { |idx| hunk << " #{before[idx]}" }

      diff = hunk.join("\n")
      fuzzy ? "(fuzzy match — whitespace differences were ignored)\n#{diff}" : diff
    end
  end
end
