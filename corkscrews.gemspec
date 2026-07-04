# frozen_string_literal: true

require_relative "lib/corkscrews/version"

Gem::Specification.new do |spec|
  spec.name = "corkscrews"
  spec.version = Corkscrews::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Causal profiling tools for Ruby bottleneck experiments."
  spec.description = "corkscrews records progress points, line samples, wait targets, and validation benchmarks for Ruby causal profiling experiments."
  spec.homepage = "https://github.com/ydah/corkscrews"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3.0"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.extensions = ["ext/corkscrews/extconf.rb"]
  spec.require_paths = ["lib"]

  spec.add_dependency "fiddle"
end
