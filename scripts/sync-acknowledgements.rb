#!/usr/bin/env ruby

# Generates the About > Libraries list from the license of every library the
# app ships:
#
#   ruby scripts/sync-acknowledgements.rb           # regenerate the plist
#   ruby scripts/sync-acknowledgements.rb --check   # fail on drift (verify gate)
#
# Swift packages are read from a resolved checkout at the revision
# Package.resolved pins, so resolve packages first (`mise run bootstrap`).
# PUTIO_SOURCE_PACKAGES names a SourcePackages directory to read instead of
# DerivedData.

require "json"

class AcknowledgementsSync
  ROOT = File.expand_path("..", __dir__)
  RESOLVED_PATH = File.join(ROOT, "Putio.xcworkspace", "xcshareddata", "swiftpm", "Package.resolved")
  PODFILE_LOCK_PATH = File.join(ROOT, "Podfile.lock")
  PLIST_PATH = File.join(ROOT, "Putio", "Features", "Settings", "About", "Acknowledgements.plist")

  APP_PACKAGES = {
    "intercom-ios-sp" => "Intercom",
    "keychainaccess" => "KeychainAccess",
    "posthog-ios" => "PostHog",
    "putio-sdk-swift" => "PutioSDK",
    "realm-core" => "Realm Core",
    "realm-swift" => "RealmSwift",
    "sentry-cocoa" => "Sentry",
  }.freeze
  TEST_PACKAGES = %w[swift-custom-dump swift-issue-reporting swift-snapshot-testing swift-syntax].freeze

  LOCAL_LICENSES = {
    "Phosphor Icons" => "ThirdParty/PhosphorIcons/LICENSE",
    "StatefulViewController" => "ThirdParty/StatefulViewController/LICENSE",
  }.freeze

  PODS = {
    "google-cast-sdk" => ["Google Cast SDK", { text: "https://developers.google.com/terms/" }],
    "Protobuf" => ["Protobuf", { path: "Pods/Protobuf/LICENSE" }],
  }.freeze

  LICENSE_NAMES = %w[LICENSE LICENSE.md LICENSE.txt LICENCE].freeze

  def initialize(check_only:)
    @check_only = check_only
  end

  def run
    entries = package_entries + local_entries + pod_entries
    entries.sort_by! { |title, _| title.downcase }
    plist = render(entries)
    if @check_only
      current = File.exist?(PLIST_PATH) ? File.binread(PLIST_PATH) : "".b
      fail!("Acknowledgements.plist is out of sync with the shipped libraries. Run: mise run acknowledgements-sync") if current != plist.b
      puts "Verified #{entries.size} acknowledgements."
    else
      File.write(PLIST_PATH, plist)
      puts "Generated Acknowledgements.plist (#{entries.size} libraries)."
    end
  end

  private

  def fail!(message)
    warn "sync-acknowledgements: #{message}"
    exit 1
  end

  def package_entries
    pins = JSON.parse(File.read(RESOLVED_PATH)).fetch("pins")
    unknown = pins.map { |pin| pin.fetch("identity") } - APP_PACKAGES.keys - TEST_PACKAGES
    fail!("classify #{unknown.join(", ")} in APP_PACKAGES or TEST_PACKAGES") unless unknown.empty?

    pins.filter_map do |pin|
      title = APP_PACKAGES[pin.fetch("identity")]
      next unless title

      [title, license_in(checkout_for(pin))]
    end
  end

  def checkout_for(pin)
    name = File.basename(pin.fetch("location"), ".git")
    revision = pin.fetch("state").fetch("revision")
    checkout = source_package_dirs.map { |dir| File.join(dir, "checkouts", name) }.find do |path|
      File.directory?(path) && git_head(path) == revision
    end
    checkout || fail!("no checkout of #{name} at #{revision[0, 7]}; resolve packages first (mise run bootstrap)")
  end

  def source_package_dirs
    @source_package_dirs ||= if ENV["PUTIO_SOURCE_PACKAGES"]
      [ENV.fetch("PUTIO_SOURCE_PACKAGES")]
    else
      Dir.glob(File.expand_path("~/Library/Developer/Xcode/DerivedData/Putio-*/SourcePackages"))
    end
  end

  def git_head(path)
    IO.popen(["git", "-C", path, "rev-parse", "HEAD"], err: File::NULL, &:read).strip
  end

  def license_in(dir)
    path = LICENSE_NAMES.map { |name| File.join(dir, name) }.find { |candidate| File.file?(candidate) }
    path || fail!("no license file in #{dir}")
    normalize(File.read(path))
  end

  def local_entries
    LOCAL_LICENSES.map { |title, path| [title, normalize(File.read(File.join(ROOT, path)))] }
  end

  def pod_entries
    pods = File.read(PODFILE_LOCK_PATH)[/^PODS:\n(.*?)\n\n/m, 1].scan(/^  - ([^\s(]+)/).flatten
    unknown = pods - PODS.keys
    fail!("add #{unknown.join(", ")} to PODS") unless unknown.empty?

    pods.map do |pod|
      title, source = PODS.fetch(pod)
      [title, source[:text] || normalize(File.read(File.join(ROOT, source.fetch(:path))))]
    end
  end

  def normalize(text)
    text.gsub("\r\n", "\n").gsub(/[ \t]+$/, "").sub(/\A\n+/, "").rstrip
  end

  def render(entries)
    items = entries.map do |title, license|
      "\t<dict>\n\t\t<key>license</key>\n\t\t<string>#{escape(license)}</string>\n" \
        "\t\t<key>title</key>\n\t\t<string>#{escape(title)}</string>\n\t</dict>\n"
    end
    <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <array>
      #{items.join.chomp}
      </array>
      </plist>
    PLIST
  end

  def escape(text)
    text.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end
end

AcknowledgementsSync.new(check_only: ARGV.include?("--check")).run
