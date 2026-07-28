#!/usr/bin/env ruby
# frozen_string_literal: true

# Syncs the licensed brand fonts from static.put.io into gitignored
# Putio/Fonts/. The same files the web app already serves to browsers, so no
# credentials, no private repository access, and no GitHub CLI.
#
# The fonts are licensed and must never be committed here — `make verify-fast`
# fails if any font binary is tracked.
#
# Usage:
#   ruby scripts/sync-brand-fonts.rb           # download any missing or stale font
#   ruby scripts/sync-brand-fonts.rb --check   # report status, no writes

require "digest"
require "json"
require "net/http"
require "uri"

class BrandFontSync
  MAX_REDIRECTS = 3

  # Anchored on the script's own location, not the working directory, so the
  # script can be invoked by absolute path from anywhere without reading the
  # wrong manifest or writing to the wrong Putio/Fonts.
  ROOT = File.expand_path("..", __dir__)
  MANIFEST_PATH = File.join(ROOT, "Config", "BrandFonts.json")

  def initialize(check_only:)
    @check_only = check_only
    @manifest = JSON.parse(File.read(MANIFEST_PATH))
    @base_url = @manifest.fetch("baseUrl")
    @directory_label = @manifest.fetch("directory")
    @directory = File.join(ROOT, @directory_label)
    @files = @manifest.fetch("files")
  end

  def run
    @check_only ? check : sync
  end

  private

  def check
    stale = @files.reject { |name, entry| current?(name, entry.fetch("sha256")) }.keys
    mismatched = stale.select { |name| File.exist?(font_path(name)) }
    # Checked even when every manifest font is current: the build bundles
    # whatever sits in this directory, so an unlisted face would otherwise reach
    # a distributed build unnoticed.
    unlisted = unlisted_font_files

    unless mismatched.empty? && unlisted.empty?
      details = []
      details << "  mismatched: #{mismatched.join(', ')}" unless mismatched.empty?
      details << "  unlisted: #{unlisted.join(', ')}" unless unlisted.empty?

      abort [
        "sync-brand-fonts: #{@directory_label} contradicts Config/BrandFonts.json.",
        *details,
        "  fix: rm -rf #{@directory_label} && make fonts-setup",
      ].join("\n")
    end

    if stale.empty?
      puts "sync-brand-fonts: #{@files.size} brand fonts present and matching the manifest."
      return
    end

    # Absent fonts are a normal state: the app falls back to system faces, and
    # only the snapshot suites require them.
    present = @files.keys - stale
    if present.empty?
      puts "sync-brand-fonts: no brand fonts present; run `make fonts-setup` to download them."
      return
    end

    # A partial set is neither of the two good states. It means a sync failed
    # part way, and the build would bundle some faces while falling back to
    # system fonts for the rest — the one outcome nothing else detects.
    abort [
      "sync-brand-fonts: #{@directory_label} has #{present.size} of #{@files.size} brand fonts.",
      "  missing: #{stale.sort.join(', ')}",
      "  fix: make fonts-setup",
    ].join("\n")
  end

  def sync
    FileUtils.mkdir_p(@directory)

    @files.each do |name, entry|
      if current?(name, entry.fetch("sha256"))
        puts "sync-brand-fonts: #{name} already current"
        next
      end

      download(name, entry)
    end

    # The Xcode build phase globs this directory, so an unlisted face would be
    # bundled. Report it here too rather than only in --check, so a bare
    # `make fonts-setup` cannot claim success over a contradictory directory.
    unlisted = unlisted_font_files
    unless unlisted.empty?
      abort [
        "sync-brand-fonts: #{@directory_label} contains fonts that are not in the manifest.",
        "  unlisted: #{unlisted.join(', ')}",
        "  fix: rm -rf #{@directory_label} && make fonts-setup",
      ].join("\n")
    end

    puts "sync-brand-fonts: #{@files.size} brand fonts ready in #{@directory_label}."
  end

  def download(name, entry)
    url = "#{@base_url}/#{entry.fetch('path')}"
    body = fetch(url)
    actual = Digest::SHA256.hexdigest(body)
    expected = entry.fetch("sha256")

    # These files feed pixel-compared snapshot baselines, so a silently
    # re-uploaded font would surface as 23 unexplained image diffs. Checking the
    # hash turns that into one clear message.
    unless actual == expected
      abort <<~MESSAGE
        sync-brand-fonts: #{name} does not match the manifest.
          url:      #{url}
          expected: #{expected}
          actual:   #{actual}
        The hosted font changed. Confirm the new file is intended, update its
        sha256 in Config/BrandFonts.json, then re-record baselines with
        `make screenshots-record`.
      MESSAGE
    end

    File.binwrite(font_path(name), body)
    puts "sync-brand-fonts: downloaded #{name} (#{body.bytesize} bytes)"
  end

  def fetch(url, redirects_left = MAX_REDIRECTS)
    response = Net::HTTP.get_response(URI.parse(url))

    case response
    when Net::HTTPSuccess
      response.body
    when Net::HTTPRedirection
      abort "sync-brand-fonts: too many redirects fetching #{url}" if redirects_left.zero?
      location = response["location"]
      abort "sync-brand-fonts: #{url} redirected without a Location header" if location.nil?
      # A Location may legally be relative, so resolve it against the URL that
      # produced it rather than parsing it standalone.
      fetch(URI.join(url, location).to_s, redirects_left - 1)
    else
      abort "sync-brand-fonts: #{url} returned #{response.code} #{response.message}"
    end
  rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout => e
    abort "sync-brand-fonts: could not reach #{url} (#{e.class}). Check your network."
  end

  def current?(name, sha)
    path = font_path(name)
    File.exist?(path) && Digest::SHA256.file(path).hexdigest == sha
  end

  def font_path(name)
    File.join(@directory, name)
  end

  # Mirrors the copy glob in the "Bundle brand fonts" build phase, which takes
  # gt-america-*.otf and berkeley-mono-*.otf and nothing else. Keeping the two
  # in step means this reports exactly the files that could reach a build, so an
  # unrelated face sitting in the directory is inert rather than a hard failure.
  BUNDLED_FONT_PATTERN = /\A(?:gt-america|berkeley-mono)-.*\.otf\z/i

  def unlisted_font_files
    return [] unless Dir.exist?(@directory)

    Dir.children(@directory)
       .select { |name| name.match?(BUNDLED_FONT_PATTERN) }
       .reject { |name| @files.key?(name) }
       .sort
  end
end

require "fileutils"

BrandFontSync.new(check_only: ARGV.include?("--check")).run
