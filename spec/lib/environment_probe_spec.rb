# frozen_string_literal: true

require "rails_helper"

RSpec.describe EnvironmentProbe do
  let(:pwd) { Dir.mktmpdir("env-probe-") }

  before do
    allow(Anima::Settings).to receive(:project_files_whitelist)
      .and_return(["CLAUDE.md", "AGENTS.md", "README.md", "CONTRIBUTING.md"])
    allow(Anima::Settings).to receive(:project_files_max_depth).and_return(3)
    allow(Anima::Settings).to receive(:web_request_timeout).and_return(5)
  end

  after { FileUtils.remove_entry(pwd) }

  describe ".to_prompt" do
    it "returns nil when pwd is nil" do
      expect(described_class.to_prompt(nil)).to be_nil
    end

    it "returns a string starting with ## Environment" do
      stub_no_git

      result = described_class.to_prompt(pwd)
      expect(result).to start_with("## Environment")
    end

    it "includes OS information" do
      stub_no_git

      result = described_class.to_prompt(pwd)
      expect(result).to include("OS:")
    end

    it "includes the working directory" do
      stub_no_git

      result = described_class.to_prompt(pwd)
      expect(result).to include("CWD: #{pwd}")
    end
  end

  describe "OS detection" do
    before { stub_no_git }

    it "formats Linux with distro and package manager" do
      allow(Etc).to receive(:uname).and_return({sysname: "Linux"})
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/etc/os-release").and_return(true)
      allow(File).to receive(:foreach).with("/etc/os-release").and_yield('PRETTY_NAME="Arch Linux"')
      allow(File).to receive(:exist?).with("/usr/bin/pacman").and_return(true)
      allow(File).to receive(:exist?).with("/usr/bin/yay").and_return(true)

      result = described_class.to_prompt(pwd)
      expect(result).to include("OS: Arch Linux (pacman, yay)")
    end

    it "formats macOS with Homebrew" do
      allow(Etc).to receive(:uname).and_return({sysname: "Darwin"})

      result = described_class.to_prompt(pwd)
      expect(result).to include("OS: macOS (Homebrew)")
    end

    it "falls back to sysname for unknown OS" do
      allow(Etc).to receive(:uname).and_return({sysname: "FreeBSD"})

      result = described_class.to_prompt(pwd)
      expect(result).to include("OS: FreeBSD")
    end

    it "shows distro without package manager when none detected" do
      allow(Etc).to receive(:uname).and_return({sysname: "Linux"})
      allow(File).to receive(:exist?).and_call_original
      allow(File).to receive(:exist?).with("/etc/os-release").and_return(true)
      allow(File).to receive(:foreach).with("/etc/os-release").and_yield('PRETTY_NAME="Custom Linux"')
      allow(File).to receive(:exist?).with("/usr/bin/pacman").and_return(false)
      allow(File).to receive(:exist?).with("/usr/bin/yay").and_return(false)
      allow(File).to receive(:exist?).with("/usr/bin/apt").and_return(false)
      allow(File).to receive(:exist?).with("/usr/bin/dnf").and_return(false)
      allow(File).to receive(:exist?).with("/opt/homebrew/bin/brew").and_return(false)
      allow(File).to receive(:exist?).with("/usr/local/bin/brew").and_return(false)

      result = described_class.to_prompt(pwd)
      expect(result).to include("OS: Custom Linux")
      expect(result).not_to match(/Custom Linux \(/)
    end
  end

  describe "Git detection" do
    it "includes Git metadata when in a repo" do
      init_git_repo(pwd, remote: "git@github.com:user/my-app.git", branch: "feature/auth")

      result = described_class.to_prompt(pwd)
      expect(result).to include("Git: user/my-app (git@github.com:user/my-app.git)")
      expect(result).to include("Branch: feature/auth")
    end

    it "handles HTTPS remote URLs" do
      init_git_repo(pwd, remote: "https://github.com/user/my-app.git")

      result = described_class.to_prompt(pwd)
      expect(result).to include("Git: user/my-app")
    end

    it "omits Git section when not in a repo" do
      stub_no_git

      result = described_class.to_prompt(pwd)
      expect(result).not_to include("Git:")
      expect(result).not_to include("Branch:")
    end

    it "omits PR line when no PR exists" do
      init_git_repo(pwd)

      result = described_class.to_prompt(pwd)
      expect(result).not_to include("PR:")
    end

    it "includes PR status when a PR exists" do
      init_git_repo(pwd)
      stub_pr(number: 42, state: "OPEN")

      result = described_class.to_prompt(pwd)
      expect(result).to include("PR: #42 (open)")
    end

    it "handles git not being installed" do
      allow(Open3).to receive(:capture2).and_call_original
      allow(Open3).to receive(:capture2)
        .with("git", "-C", pwd, "rev-parse", "--is-inside-work-tree")
        .and_raise(Errno::ENOENT)

      result = described_class.to_prompt(pwd)
      expect(result).not_to include("Git:")
    end

    it "handles gh not being installed" do
      init_git_repo(pwd)
      allow(Open3).to receive(:capture2)
        .with("gh", "pr", "list", "--head", anything, "--json", "number,state", "--limit", "1", chdir: pwd)
        .and_raise(Errno::ENOENT)

      result = described_class.to_prompt(pwd)
      expect(result).to include("Branch:")
      expect(result).not_to include("PR:")
    end
  end

  describe "project file scanning" do
    before { stub_no_git }

    it "lists project files found at root" do
      FileUtils.touch(File.join(pwd, "CLAUDE.md"))
      FileUtils.touch(File.join(pwd, "README.md"))

      result = described_class.to_prompt(pwd)
      expect(result).to include("- CLAUDE.md")
      expect(result).to include("- README.md")
    end

    it "lists project files found in subdirectories" do
      docs_dir = File.join(pwd, "docs")
      FileUtils.mkdir_p(docs_dir)
      FileUtils.touch(File.join(docs_dir, "CONTRIBUTING.md"))

      result = described_class.to_prompt(pwd)
      expect(result).to include("- docs/CONTRIBUTING.md")
    end

    it "includes guidance to use read_file" do
      FileUtils.touch(File.join(pwd, "README.md"))

      result = described_class.to_prompt(pwd)
      expect(result).to include("Use read_file to examine these when needed.")
    end

    it "omits project files section when none found" do
      result = described_class.to_prompt(pwd)
      expect(result).not_to include("Project files")
    end

    it "respects max depth setting" do
      deep_dir = File.join(pwd, "a", "b", "c", "d")
      FileUtils.mkdir_p(deep_dir)
      FileUtils.touch(File.join(deep_dir, "README.md"))

      allow(Anima::Settings).to receive(:project_files_max_depth).and_return(2)

      result = described_class.to_prompt(pwd)
      expect(result).not_to include("a/b/c/d/README.md")
    end

    it "deduplicates and sorts results" do
      FileUtils.touch(File.join(pwd, "README.md"))
      FileUtils.touch(File.join(pwd, "CLAUDE.md"))

      result = described_class.to_prompt(pwd)
      claude_pos = result.index("CLAUDE.md")
      readme_pos = result.index("README.md")
      expect(claude_pos).to be < readme_pos
    end
  end

  # --- Helpers ---

  def stub_no_git
    allow(Open3).to receive(:capture2).and_call_original
    allow(Open3).to receive(:capture2)
      .with("git", "-C", pwd, "rev-parse", "--is-inside-work-tree")
      .and_return(["false\n", instance_double(Process::Status, success?: false)])
  end

  def init_git_repo(dir, remote: "git@github.com:user/repo.git", branch: "main")
    system("git", "-C", dir, "init", "-b", branch, out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "remote", "add", "origin", remote, out: File::NULL, err: File::NULL)
    system("git", "-C", dir, "commit", "--allow-empty", "-m", "init", out: File::NULL, err: File::NULL)
    # Allow real git calls to pass through, but stub gh
    allow(Open3).to receive(:capture2).and_call_original
    allow(Open3).to receive(:capture2)
      .with("gh", "pr", "list", "--head", anything, "--json", "number,state", "--limit", "1", chdir: dir)
      .and_return(["[]\n", instance_double(Process::Status, success?: true)])
  end

  def stub_pr(number:, state:)
    allow(Open3).to receive(:capture2)
      .with("gh", "pr", "list", "--head", anything, "--json", "number,state", "--limit", "1", chdir: pwd)
      .and_return(["[{\"number\":#{number},\"state\":\"#{state}\"}]\n",
        instance_double(Process::Status, success?: true)])
  end
end
