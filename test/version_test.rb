# frozen_string_literal: true

# The version is defined once (Skaidb::VERSION); the gemspec reads it and the
# Hello frame carries it. These pin all three together.
require "test_helper"

class VersionTest < Minitest::Test
  include ServerHelpers

  ROOT = File.expand_path("..", __dir__)

  def test_version_is_semver
    assert_match(/\A\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?\z/, Skaidb::VERSION)
  end

  def test_gemspec_reads_the_constant
    spec = Gem::Specification.load(File.join(ROOT, "skaidb.gemspec"))
    assert_equal Skaidb::VERSION, spec.version.to_s
    assert_equal "skaidb", spec.name
    assert_includes File.read(File.join(ROOT, "skaidb.gemspec")), "Skaidb::VERSION"
  end

  def test_hello_derives_its_version_from_the_constant_not_a_literal
    src = File.read(File.join(ROOT, "lib", "skaidb.rb"))
    hello = src[/def send_hello.*?^    end/m]
    refute_nil hello, "send_hello not found"
    assert_includes hello, "Skaidb::VERSION"
    refute_match(/["']\d+\.\d+\.\d+["']/, hello, "send_hello must not hard-code a version")
  end

  def test_hello_frame_carries_name_ruby_and_the_package_version
    with_server do |srv|
      c = connect(srv)
      c.close
      assert_equal 1, srv.hellos.length
      assert_equal "ruby", srv.hellos[0].name
      assert_equal Skaidb::VERSION, srv.hellos[0].version
      # nothing trailing after the two strings
      expected = [8].pack("C") + Skaidb.enc_str("ruby") + Skaidb.enc_str(Skaidb::VERSION)
      assert_equal expected, srv.hellos[0].raw
    end
  end

  def test_changelog_has_an_entry_for_this_version
    changelog = File.read(File.join(ROOT, "CHANGELOG.md"))
    assert_includes changelog, "## [#{Skaidb::VERSION}]"
  end
end
