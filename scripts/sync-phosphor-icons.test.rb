require "fileutils"
require "minitest/autorun"
require "tmpdir"
require_relative "sync-phosphor-icons"

class PhosphorIconSourcePolicyTest < Minitest::Test
  def test_allowlisted_literal_passes_with_utf8_source
    violations = scan(
      {
        "Putio/Allowed.swift" => <<~SWIFT
          let title = "15×"
          let image = UIImage(systemName: "gobackward.15")
        SWIFT
      },
      allowlist: { "Putio/Allowed.swift" => ["gobackward.15"] }
    )

    assert_empty violations
  end

  def test_unapproved_literal_fails
    violations = scan({ "Putio/Unapproved.swift" => 'let image = UIImage(systemName: "heart")' })

    assert_equal ["Putio/Unapproved.swift"], violations
  end

  def test_dynamic_symbol_name_fails_the_call_count_guard
    violations = scan({ "Putio/Dynamic.swift" => "let image = UIImage(systemName: symbolName)" })

    assert_equal ["Putio/Dynamic.swift"], violations
  end

  def test_allowlist_is_scoped_to_the_exact_relative_path
    violations = scan(
      { "Putio/Actual.swift" => 'let image = UIImage(systemName: "gobackward.15")' },
      allowlist: { "Putio/Typo.swift" => ["gobackward.15"] }
    )

    assert_equal ["Putio/Actual.swift"], violations
  end

  def test_concatenated_allowlisted_prefix_fails
    violations = scan(
      { "Putio/Allowed.swift" => 'let image = UIImage(systemName: "gobackward.15" + ".fill")' },
      allowlist: { "Putio/Allowed.swift" => ["gobackward.15"] }
    )

    assert_equal ["Putio/Allowed.swift"], violations
  end

  private

  def scan(sources, allowlist: {})
    Dir.mktmpdir do |root|
      sources.each do |relative_path, source|
        path = File.join(root, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, source, encoding: Encoding::UTF_8)
      end

      return PhosphorIconSync.source_policy_violations(root: root, allowlist: allowlist)
    end
  end
end
