# frozen_string_literal: true

require "etc"
require "open3"
require "timeout"
require "json"
require "pathname"

# Probes the shell environment and assembles a lightweight metadata block
# for injection into the system prompt. Gives the agent awareness of its
# working directory, OS, Git status, and nearby project files — without
# loading any file content.
#
# @example
#   EnvironmentProbe.to_prompt("/home/user/projects/my-app")
#   # => "## Environment\n\nOS: Arch Linux (pacman, yay)\n..."
class EnvironmentProbe
  # Assembles the environment context block for a given working directory.
  #
  # @param pwd [String, nil] current working directory
  # @return [String, nil] Markdown-formatted environment block, or nil when pwd is unknown
  def self.to_prompt(pwd)
    new(pwd).to_prompt
  end

  # @param pwd [String, nil] current working directory
  def initialize(pwd)
    @pwd = pwd
  end

  # @return [String, nil] Markdown-formatted environment block
  def to_prompt
    return unless @pwd

    sections = [os_section, working_directory_section, project_files_section].compact
    return if sections.empty?

    "## Environment\n\n#{sections.join("\n\n")}"
  end

  private

  # @return [String] OS name with package manager hint
  def os_section
    sysname = Etc.uname[:sysname]
    "OS: #{format_os(sysname)}"
  end

  # @param sysname [String] kernel name from uname (e.g. "Linux", "Darwin")
  # @return [String] human-readable OS description
  def format_os(sysname)
    case sysname
    when "Linux"
      distro = detect_linux_distro || "Linux"
      pkg = detect_package_manager
      pkg ? "#{distro} (#{pkg})" : distro
    when "Darwin"
      "macOS (Homebrew)"
    else
      sysname
    end
  end

  # Reads PRETTY_NAME from /etc/os-release.
  #
  # @return [String, nil] distro name, or nil on non-Linux / missing file
  def detect_linux_distro
    return unless File.exist?("/etc/os-release")

    File.foreach("/etc/os-release") do |line|
      if line.start_with?("PRETTY_NAME=")
        return line.split("=", 2).last.strip.delete('"')
      end
    end
    nil
  end

  # Detects available package managers by checking well-known binary paths.
  #
  # @return [String, nil] comma-separated package manager names
  def detect_package_manager
    managers = []
    managers << "pacman" if File.exist?("/usr/bin/pacman")
    managers << "yay" if File.exist?("/usr/bin/yay")
    return managers.join(", ") if managers.any?

    return "apt" if File.exist?("/usr/bin/apt")
    return "dnf" if File.exist?("/usr/bin/dnf")
    return "Homebrew" if File.exist?("/opt/homebrew/bin/brew") || File.exist?("/usr/local/bin/brew")

    nil
  end

  # @return [String] CWD line plus optional Git metadata
  def working_directory_section
    lines = ["CWD: #{@pwd}"]
    append_git_lines(lines)
    lines.join("\n")
  end

  # Appends Git metadata lines (remote, branch, PR) to the output array.
  #
  # @param lines [Array<String>] accumulator for output lines
  # @return [void]
  def append_git_lines(lines)
    git = detect_git
    return unless git

    remote = git[:remote]
    branch = git[:branch]
    pr_number = git[:pr_number]

    lines << "Git: #{git[:repo_name]} (#{remote})" if remote
    lines << "Branch: #{branch}" if branch
    lines << "PR: ##{pr_number} (#{git[:pr_state]})" if pr_number
  end

  # Detects Git repo metadata: remote, branch, and open PR.
  #
  # @return [Hash, nil] Git info hash, or nil when not in a repo
  def detect_git
    _, status = Open3.capture2("git", "-C", @pwd, "rev-parse", "--is-inside-work-tree")
    return unless status.success?

    info = {}
    detect_git_remote(info)
    detect_git_branch(info)
    info
  rescue Errno::ENOENT
    nil
  end

  # Populates :remote and :repo_name on the info hash.
  def detect_git_remote(info)
    remote, = Open3.capture2("git", "-C", @pwd, "remote", "get-url", "origin")
    remote = remote.strip
    return unless remote.present?

    info[:remote] = remote
    info[:repo_name] = extract_repo_name(remote)
  end

  # Populates :branch, :pr_number, and :pr_state on the info hash.
  def detect_git_branch(info)
    branch, = Open3.capture2("git", "-C", @pwd, "rev-parse", "--abbrev-ref", "HEAD")
    branch = branch.strip
    return unless branch.present?

    info[:branch] = branch
    pr = detect_pr(branch)
    info.merge!(pr) if pr
  end

  # Extracts owner/repo from a Git remote URL.
  #
  # @param remote_url [String] SSH or HTTPS remote URL
  # @return [String] "owner/repo" path
  def extract_repo_name(remote_url)
    path = if remote_url.match?(%r{\A\w+://})
      URI.parse(remote_url).path
    else
      # SSH format: git@host:owner/repo.git
      remote_url.split(":").last
    end
    path.delete_prefix("/").delete_suffix(".git")
  rescue
    remote_url
  end

  # Queries GitHub for an open PR on the given branch via the gh CLI.
  #
  # @param branch [String] branch name
  # @return [Hash, nil] with :pr_number and :pr_state, or nil
  def detect_pr(branch)
    Timeout.timeout(Anima::Settings.web_request_timeout) do
      output, status = Open3.capture2(
        "gh", "pr", "list", "--head", branch,
        "--json", "number,state", "--limit", "1",
        chdir: @pwd
      )
      return unless status.success?

      pr = JSON.parse(output).first
      return unless pr

      {pr_number: pr["number"], pr_state: pr["state"].downcase}
    end
  rescue Timeout::Error, Errno::ENOENT, JSON::ParserError
    nil
  end

  # Scans for well-known project files up to a configurable depth.
  #
  # @return [String, nil] project files section, or nil when none found
  def project_files_section
    found = scan_project_files
    return if found.empty?

    header = "Project files that may contain useful context:"
    entries = found.map { |path| "- #{path}" }
    [header, *entries, "Use read_file to examine these when needed."].join("\n")
  end

  # Scans the working directory for whitelisted filenames.
  #
  # @return [Array<String>] sorted relative paths
  def scan_project_files
    base = Pathname.new(@pwd)

    glob_patterns.flat_map { |pattern| Dir.glob(pattern) }
      .map { |full_path| Pathname.new(full_path).relative_path_from(base).to_s }
      .sort
      .uniq
  end

  # Builds glob patterns for each whitelisted filename at each depth level.
  #
  # @return [Array<String>] glob patterns
  def glob_patterns
    whitelist = Anima::Settings.project_files_whitelist
    max_depth = Anima::Settings.project_files_max_depth

    whitelist.product((0..max_depth).to_a).map do |filename, depth|
      File.join(@pwd, Array.new(depth, "*"), filename)
    end
  end
end
