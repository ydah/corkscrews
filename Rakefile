# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task :compile do
  sh "cd ext/corkscrews && ruby extconf.rb && make"
end

task :validate do
  sh "ruby -Ilib exe/corkscrews validate --quick"
end

task :validate_full do
  sh "ruby -Ilib exe/corkscrews validate"
end

task default: :spec
