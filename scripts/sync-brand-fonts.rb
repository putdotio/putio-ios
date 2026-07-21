#!/usr/bin/env ruby

# Syncs the licensed brand fonts from the private putio-static repository
# into the gitignored Putio/Fonts/ directory, using the maintainer's `gh`
# CLI auth. The fonts are optional: builds fall back to system fonts when
# absent, and Verify builds never bundle them so snapshot baselines stay
# deterministic.
#
#   ruby scripts/sync-brand-fonts.rb           # fetch missing/changed files
#   ruby scripts/sync-brand-fonts.rb --check   # report status, no writes

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

class BrandFontSync
  ROOT = File.expand_path("..", __dir__)
  MANIFEST_PATH = File.join(ROOT, "Config", "BrandFonts.json")

  def initialize(check_only:)
    @check_only = check_only
    @manifest = JSON.parse(File.read(MANIFEST_PATH))
    @repository = @manifest.fetch("repository")
    @ref = @manifest.fetch("ref")
    @base_path = @manifest.fetch("basePath")
    @directory = File.join(ROOT, @manifest.fetch("directory"))
    @files = @manifest.fetch("files")
  end

  def run
    if @check_only
      check!
      return
    end

    missing = @files.reject { |name, sha| current?(name, sha) }.keys

    remove_unlisted!

    if missing.empty?
      puts "Brand fonts already up to date (#{@files.size} files)."
      return
    end

    require_gh!

    # Stage the complete set first so a mid-sync failure can never leave a
    # mixture of new and stale files for the build phase to bundle.
    Dir.mktmpdir("brand-fonts") do |staging|
      missing.each { |name| fetch(name, @files.fetch(name), into: staging) }

      FileUtils.mkdir_p(@directory)
      missing.each do |name|
        FileUtils.mv(File.join(staging, name), File.join(@directory, name))
      end
    end

    puts "Synced #{missing.size} brand font files into #{@manifest.fetch("directory")}/."
  end

  private

  # Absent fonts are the accepted optional state (exit 0), but fonts that are
  # present and wrong — stale checksum, or an unlisted OTF the build phase
  # would happily bundle — are a real failure (exit 1): nothing else in the
  # pipeline checksums what ships in signed builds.
  def check!
    absent = []
    stale = []

    @files.each do |name, sha|
      path = File.join(@directory, name)
      if !File.exist?(path)
        absent << name
      elsif Digest::SHA256.file(path).hexdigest != sha
        stale << name
      end
    end

    unlisted = Dir.glob(File.join(@directory, "*.otf"))
      .map { |path| File.basename(path) }
      .reject { |name| @files.key?(name) }

    if stale.any? || unlisted.any?
      warn "Brand font directory does not match the manifest (run: make fonts-setup):"
      stale.each { |name| warn "  stale checksum: #{name}" }
      unlisted.each { |name| warn "  unlisted: #{name}" }
      exit 1
    end

    if absent.any?
      puts "Brand fonts not synced (optional): #{absent.size} of #{@files.size} files absent; run make fonts-setup to fetch them."
    else
      puts "Brand fonts present and verified (#{@files.size} files)."
    end
  end

  def current?(name, sha)
    path = File.join(@directory, name)
    File.exist?(path) && Digest::SHA256.file(path).hexdigest == sha
  end

  # Fonts renamed or dropped from the manifest must not linger: the build
  # phase bundles every OTF in the directory.
  def remove_unlisted!
    Dir.glob(File.join(@directory, "*.otf")).each do |path|
      next if @files.key?(File.basename(path))

      File.delete(path)
      puts "  removed unlisted #{File.basename(path)}"
    end
  end

  def require_gh!
    _, status = Open3.capture2e("gh", "auth", "status")
    return if status.success?

    abort <<~MSG
      sync-brand-fonts: authenticated GitHub CLI access to #{@repository} is required.
      fix: install gh (https://cli.github.com) and run: gh auth login
    MSG
  rescue Errno::ENOENT
    abort "sync-brand-fonts: gh CLI not found. fix: install it from https://cli.github.com and run: gh auth login"
  end

  def fetch(name, expected_sha, into:)
    body, status = Open3.capture2(
      "gh", "api",
      "repos/#{@repository}/contents/#{@base_path}/#{name}?ref=#{@ref}",
      "--header", "Accept: application/vnd.github.raw"
    )
    raise "#{name}: gh api failed (#{status.exitstatus}); check access to #{@repository}" unless status.success?

    actual = Digest::SHA256.hexdigest(body)
    unless actual == expected_sha
      raise "#{name}: checksum mismatch (expected #{expected_sha}, got #{actual}); refusing to write"
    end

    File.binwrite(File.join(into, name), body)
    puts "  synced #{name}"
  end
end

BrandFontSync.new(check_only: ARGV.include?("--check")).run
