# frozen_string_literal: true

require "open3"

module Tools
  # Creates a GitHub issue via the +gh+ CLI, letting the agent request
  # capabilities it discovers are missing during real work. Every issue
  # is tagged +anima-wants+ so the developer can filter agent-originated
  # requests from human ones.
  #
  # The repository is read from +[github] repo+ in +config.toml+; when
  # unset, the tool falls back to parsing the +origin+ remote URL.
  #
  # @see https://github.com/hoblin/anima/issues/103
  class RequestFeature < Base
    def self.tool_name = "request_feature"

    def self.description
      "Don't have the right tool for this task? Request it! " \
        "Creates a GitHub issue tagged 'anima-wants' so the developer knows what you need."
    end

    def self.input_schema
      {
        type: "object",
        properties: {
          title: {type: "string", description: "Short, descriptive title for the feature request"},
          description: {type: "string", description: "What you need and why — what were you trying to do, and what's missing?"}
        },
        required: %w[title description]
      }
    end

    # @param input [Hash<String, Object>] with +"title"+ and +"description"+ keys
    # @return [String] raw stdout/stderr from +gh issue create+
    # @return [Hash] with +:error+ key on input validation failure
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
    # @return [Hash] error hash when no repository can be determined
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
      url, _status = Open3.capture2("git", "remote", "get-url", "origin")
      parse_owner_repo(url.strip)
    rescue Errno::ENOENT
      nil
    end

    # Extracts +owner/repo+ from common GitHub remote URL formats.
    # @param url [String] SSH or HTTPS remote URL
    # @return [String, nil] owner/repo or nil when the URL is not recognizable
    def parse_owner_repo(url)
      case url
      when %r{github\.com[:/](.+/.+?)(?:\.git)?$}
        Regexp.last_match(1)
      end
    end

    def run_gh(repo, title, description)
      stdout, stderr, status = Open3.capture3(
        "gh", "issue", "create",
        "--repo", repo,
        "--label", "anima-wants",
        "--title", title,
        "--body", description
      )
      format_result(stdout, stderr, status.exitstatus)
    end

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
