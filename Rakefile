# frozen_string_literal: true

require "rake/testtask"

# Unit tests: no server needed (an in-process fake server does the talking).
Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/*_test.rb"]
  t.warning = true
end

namespace :test do
  desc "End-to-end test against a real server (SKAIDB_LIVE=1, SKAIDB_HOST/PORT/USER/PASSWORD/DATABASE)"
  Rake::TestTask.new(:live) do |t|
    t.libs << "lib" << "test"
    t.test_files = FileList["test/live/*_test.rb"]
  end
end

desc "Build the gem"
task :build do
  sh "gem build skaidb.gemspec"
end

task default: :test
