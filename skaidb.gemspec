# frozen_string_literal: true

require_relative "lib/skaidb"

Gem::Specification.new do |spec|
  spec.name        = "skaidb"
  spec.version     = Skaidb::VERSION # defined once, in lib/skaidb.rb
  spec.license     = "SSPL-1.0"
  spec.summary     = "Official Ruby driver for skaidb (binary wire protocol, pg-style API)"
  spec.description = "A pure-stdlib Ruby client for skaidb. Speaks the binary " \
                     "wire protocol with SCRAM-SHA-256 auth and exposes a " \
                     "ruby-pg-style API (exec / exec_params, $1 placeholders, " \
                     "PG::Result-shaped results, streaming, batches, pooling, TLS)."
  spec.authors     = ["skaidb contributors"]
  spec.homepage    = "https://github.com/porcupin26/skaidb-ruby"

  spec.metadata = {
    "source_code_uri" => "https://github.com/porcupin26/skaidb-ruby",
    "changelog_uri" => "https://github.com/porcupin26/skaidb-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://github.com/porcupin26/skaidb-ruby/tree/main/docs",
    "bug_tracker_uri" => "https://github.com/porcupin26/skaidb-ruby/issues",
    # "rubygems_mfa_required" => "true" is deliberately not set: rubygems.org
    # refuses every push of a gem that carries it unless the pushing account
    # has MFA enabled, and the account behind the CI key (RUBYGEMS_API_KEY)
    # has none yet. Enable MFA at the "UI and gem signin" level on that
    # account (https://rubygems.org/settings/edit), then put the line back;
    # API-key pushes keep working at that level.
  }

  spec.required_ruby_version = ">= 2.7"

  # bigdecimal ships with Ruby but is a bundled (not default) gem since 3.4,
  # so it has to be declared for Bundler users; there is no third-party code.
  spec.add_dependency "bigdecimal", ">= 2.0", "< 5"

  spec.files = ["lib/skaidb.rb", "README.md", "CHANGELOG.md", "LICENSE"] + Dir["docs/*.md"]
  spec.require_paths = ["lib"]
end
