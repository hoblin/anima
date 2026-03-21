# frozen_string_literal: true

require_relative "lib/anima/version"

Gem::Specification.new do |spec|
  spec.name = "anima-core"
  spec.version = Anima::VERSION
  spec.authors = ["Yevhenii Hurin"]
  spec.email = ["evgeny.gurin@gmail.com"]

  spec.summary = "A personal AI agent with desires, personality, and personal growth"
  spec.homepage = "https://github.com/hoblin/anima"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/hoblin/anima"
  spec.metadata["changelog_uri"] = "https://github.com/hoblin/anima/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      f.start_with?(*%w[bin/console bin/dev bin/setup .gitignore .rspec spec/ .github/ .standard.yml thoughts/ CLAUDE.md .mise.toml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "draper", "~> 4.0"
  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "foreman", "~> 0.88"
  spec.add_dependency "httparty", "~> 0.24"
  spec.add_dependency "mcp", "~> 0.8"
  spec.add_dependency "puma", "~> 6.0"
  spec.add_dependency "rails", "~> 8.1"
  spec.add_dependency "ratatui_ruby", "~> 1.4"
  spec.add_dependency "reverse_markdown", "~> 3.0"
  spec.add_dependency "solid_cable", "~> 3.0"
  spec.add_dependency "solid_queue", "~> 1.1"
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "toml-rb", "~> 4.0"
  spec.add_dependency "toon-ruby", "~> 0.1"
  spec.add_dependency "websocket-client-simple", "~> 0.8"
end
