# frozen_string_literal: true

require_relative "lib/anima/version"

Gem::Specification.new do |spec|
  spec.name = "anima-core"
  spec.version = Anima::VERSION
  spec.authors = ["Yevhenii Hurin"]
  spec.email = ["evgeny.gurin@gmail.com"]

  spec.summary = "Ruby framework for building AI agents with desires, personality, and personal growth"
  spec.homepage = "https://github.com/hoblin/anima"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/hoblin/anima"
  spec.metadata["changelog_uri"] = "https://github.com/hoblin/anima/blob/main/CHANGELOG.md"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .standard.yml thoughts/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
