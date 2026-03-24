# frozen_string_literal: true

require "open3"

module Tools
  # Opens a GitHub issue on Anima's repository via the +gh+ CLI,
  # giving the agent a voice to report bugs, pain points, or ideas.
  # Every issue is tagged with the label from +[github] label+ in
  # +config.toml+ so maintainers can filter agent-originated issues.
  #
  # The repository is read from +[github] repo+ in +config.toml+; when
  # unset, the tool falls back to parsing the +origin+ remote URL.
  #
  # @see https://github.com/hoblin/anima/issues/103
  class OpenIssue < Base
    # @return [String] tool identifier used in the Anthropic API schema
    def self.tool_name = "open_issue"

    # @return [String] description shown to the LLM
    def self.description = "Something broken, missing, or could be better in Anima? Say it here."

    # @return [Hash] JSON Schema for the tool's input parameters
    def self.input_schema
      {
        type: "object",
        properties: {
          title: {type: "string"},
          description: {type: "string", description: "Use gh-issue skill for guidance."}
        },
        required: %w[title description]
      }
    end

    # @param input [Hash<String, Object>] with +"title"+ and +"description"+ keys
    # @return [String] formatted gh command output (stdout, stderr, and exit code if non-zero)
    # @return [Hash{Symbol => String}] with +:error+ key on validation or repo resolution failure
    def execute(input)
      title = input["title"].to_s.strip
      description = input["description"].to_s.strip
      return {error: "Title cannot be blank"} if title.empty?
      return {error: "Description cannot be blank"} if description.empty?

      repo = resolve_repo
      return repo if repo.is_a?(Hash)

      run_gh(repo, title, description)
    end

    private

    # Resolves the target repository: config.toml setting first, then git remote origin.
    # @return [String] owner/repo identifier
    # @return [Hash{Symbol => String}] error hash when no repository can be determined
    def resolve_repo
      repo = settings_repo || git_remote_repo
      return {error: "Cannot determine repository. Set [github] repo in config.toml or ensure a git remote origin exists."} unless repo

      repo
    end

    # @return [String, nil] repo from config.toml, nil when not configured
    def settings_repo
      value = Anima::Settings.github_repo
      value unless value.to_s.strip.empty?
    rescue Anima::Settings::MissingSettingError
      nil
    end

    # @return [String, nil] owner/repo parsed from +git remote get-url origin+
    def git_remote_repo
      url, status = Open3.capture2("git", "remote", "get-url", "origin", err: File::NULL)
      return unless status.success?

      parse_owner_repo(url.strip)
    rescue Errno::ENOENT
      nil
    end

    # Extracts +owner/repo+ from common GitHub remote URL formats.
    # @param url [String] SSH or HTTPS remote URL
    # @return [String, nil] owner/repo or nil when the URL is not recognizable
    def parse_owner_repo(url)
      case url
      when %r{github\.com[:/]([^/]+/[^/]+?)(?:\.git)?$}
        Regexp.last_match(1)
      end
    end

    # Invokes +gh issue create+ and returns the formatted output.
    # @param repo [String] owner/repo identifier
    # @param title [String] issue title
    # @param description [String] issue body
    # @return [String] formatted command output
    def run_gh(repo, title, description)
      stdout, stderr, status = Open3.capture3(
        "gh", "issue", "create",
        "--repo", repo,
        "--label", Anima::Settings.github_label,
        "--title", title,
        "--body", description
      )
      format_result(stdout, stderr, status.exitstatus)
    end

    # Combines stdout, stderr, and exit code into a single string response.
    # @param stdout [String] captured standard output
    # @param stderr [String] captured standard error
    # @param exit_code [Integer] process exit status
    # @return [String] joined non-empty parts separated by blank lines
    def format_result(stdout, stderr, exit_code)
      out = stdout.strip
      err = stderr.strip
      parts = []
      parts << out unless out.empty?
      parts << err unless err.empty?
      parts << "exit_code: #{exit_code}" unless exit_code.zero?
      parts.join("\n\n")
    end
  end
end
