#!/usr/bin/env ruby

require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "rubygems/package"
require "stringio"
require "uri"
require "zlib"

class PhosphorIconSync
  ROOT = File.expand_path("..", __dir__)
  MANIFEST_PATH = File.join(ROOT, "Config", "PhosphorIcons.json")
  LOCK_PATH = File.join(ROOT, "Config", "PhosphorIcons.lock.json")
  ASSET_ROOT = File.join(ROOT, "Putio", "Assets.xcassets", "Phosphor")
  LICENSE_PATH = File.join(ROOT, "ThirdParty", "PhosphorIcons", "LICENSE")
  ALLOWED_WEIGHTS = %w[regular fill].freeze
  SF_SYMBOL_ALLOWLIST = {
    "Putio/Features/MediaPlayers/AudioPlayerViewController.swift" => %w[gobackward.15 goforward.15]
  }.freeze

  def self.source_policy_violations(root:, allowlist:)
    Dir.glob(File.join(root, "Putio", "**", "*.swift")).filter_map do |path|
      source = File.read(path, encoding: Encoding::UTF_8)
      next unless source.include?("UIImage") && source.include?("systemName")

      symbols = sf_symbol_names(source)
      next if symbols.empty?

      relative_path = path.delete_prefix("#{root}/")
      allowed_symbols = allowlist.fetch(relative_path, [])
      next if symbols.all? { |symbol| symbol && allowed_symbols.include?(symbol) }

      relative_path
    end
  end

  def self.sf_symbol_names(source)
    tokens = swift_tokens(source)
    symbols = []
    tokens.each_index do |index|
      next unless tokens[index] == [:identifier, "UIImage"]
      value_index = sf_symbol_value_index(tokens, index)
      next unless value_index

      value = tokens[value_index]
      terminator = tokens[value_index + 1]
      if value&.first == :string && [[:punctuation, ","], [:punctuation, ")"]].include?(terminator)
        symbols << value.last
      else
        symbols << nil
      end
    end
    symbols
  end

  def self.sf_symbol_value_index(tokens, index)
    if tokens[index + 1] == [:punctuation, "("] &&
       tokens[index + 2] == [:identifier, "systemName"] &&
       tokens[index + 3] == [:punctuation, ":"]
      index + 4
    elsif tokens[index + 1] == [:punctuation, "."] &&
          tokens[index + 2] == [:identifier, "init"] &&
          tokens[index + 3] == [:punctuation, "("] &&
          tokens[index + 4] == [:identifier, "systemName"] &&
          tokens[index + 5] == [:punctuation, ":"]
      index + 6
    end
  end

  def self.swift_tokens(source, index: 0, closing_parenthesis: false)
    tokens = []
    parenthesis_depth = closing_parenthesis ? 1 : 0

    while index < source.length
      if source[index, 2] == "//"
        index = source.index("\n", index + 2) || source.length
      elsif source[index, 2] == "/*"
        index = skip_swift_block_comment(source, index)
      elsif source[index].match?(/[A-Za-z_]/)
        finish = index + 1
        finish += 1 while finish < source.length && source[finish].match?(/[A-Za-z0-9_]/)
        tokens << [:identifier, source[index...finish]]
        index = finish
      elsif (delimiter = swift_string_delimiter(source, index))
        value, embedded_tokens, interpolated, index = read_swift_string(source, index, *delimiter)
        tokens << (interpolated ? [:other, "interpolated-string"] : [:string, value])
        tokens.concat(embedded_tokens)
      elsif ["(", ")", ":", ",", "."].include?(source[index])
        punctuation = source[index]
        if closing_parenthesis && punctuation == "("
          parenthesis_depth += 1
        elsif closing_parenthesis && punctuation == ")"
          parenthesis_depth -= 1
          return [tokens, index + 1] if parenthesis_depth.zero?
        end
        tokens << [:punctuation, punctuation]
        index += 1
      else
        tokens << [:other, source[index]] unless source[index].match?(/\s/)
        index += 1
      end
    end

    closing_parenthesis ? [tokens, index] : tokens
  end

  def self.skip_swift_block_comment(source, index)
    depth = 1
    index += 2
    while index < source.length && depth.positive?
      if source[index, 2] == "/*"
        depth += 1
        index += 2
      elsif source[index, 2] == "*/"
        depth -= 1
        index += 2
      else
        index += 1
      end
    end
    index
  end

  def self.swift_string_delimiter(source, index)
    hash_count = 0
    hash_count += 1 while source[index + hash_count] == "#"
    quote_index = index + hash_count
    return [hash_count, 3] if source[quote_index, 3] == '"""'
    return [hash_count, 1] if source[quote_index] == '"'

    nil
  end

  def self.read_swift_string(source, index, hash_count, quote_count)
    opening_length = hash_count + quote_count
    content_start = index + opening_length
    terminator = ('"' * quote_count) + ("#" * hash_count)
    interpolation_opener = "\\#{"#" * hash_count}("
    cursor = content_start
    embedded_tokens = []
    interpolated = false

    while cursor < source.length
      if source[cursor, terminator.length] == terminator
        return [source[content_start...cursor], embedded_tokens, interpolated, cursor + terminator.length]
      elsif source[cursor, interpolation_opener.length] == interpolation_opener
        interpolated = true
        interpolation_tokens, cursor = swift_tokens(
          source,
          index: cursor + interpolation_opener.length,
          closing_parenthesis: true
        )
        embedded_tokens.concat(interpolation_tokens)
      elsif hash_count.zero? && source[cursor] == "\\"
        cursor += 2
      else
        cursor += 1
      end
    end

    [source[content_start..], embedded_tokens, interpolated, source.length]
  end

  def initialize
    @manifest = JSON.parse(File.read(MANIFEST_PATH))
    @package = @manifest.fetch("package")
    @icons = @manifest.fetch("icons")
    validate_manifest!
  end

  def sync
    archive = download_archive
    verify_archive_integrity!(archive)
    entries = archive_entries(archive)

    FileUtils.mkdir_p(ASSET_ROOT)
    File.write(File.join(ASSET_ROOT, "Contents.json"), formatted_json(group_contents))

    generated_icons = @icons.map do |icon|
      source_path = source_path(icon)
      source = entries.fetch(source_path) do
        raise "Missing #{source_path} in #{@package.fetch("name")} #{@package.fetch("version")}" 
      end
      write_icon(icon, source, source_path)
    end

    remove_unlisted_assets(generated_icons.map { |icon| icon.fetch("asset_name") })

    license = entries.fetch("package/LICENSE")
    FileUtils.mkdir_p(File.dirname(LICENSE_PATH))
    File.write(LICENSE_PATH, license)

    lock = {
      "package" => @package.slice("name", "version", "integrity"),
      "license_sha256" => Digest::SHA256.hexdigest(license),
      "icons" => generated_icons
    }
    File.write(LOCK_PATH, formatted_json(lock))

    check
  end

  def check
    errors = []
    lock = read_json(LOCK_PATH, errors)
    check_group_contents(errors)
    check_license(lock, errors)
    check_icons(lock, errors)
    check_source_policy(errors)

    unless errors.empty?
      warn errors.map { |error| "- #{error}" }.join("\n")
      warn "Run mise run icons-sync to regenerate the pinned Phosphor assets."
      exit 1
    end

    puts "Verified #{@icons.count} pinned Phosphor icon assets."
  end

  private

  def validate_manifest!
    expected_package_keys = %w[name version tarball integrity]
    unless @package.keys.sort == expected_package_keys.sort
      raise "Phosphor package metadata must contain #{expected_package_keys.join(", ")}"
    end

    uri = URI.parse(@package.fetch("tarball"))
    unless uri.scheme == "https" && uri.host == "registry.npmjs.org"
      raise "Phosphor tarball must use the npm registry over HTTPS"
    end

    unless @package.fetch("integrity").start_with?("sha512-")
      raise "Phosphor package integrity must be a sha512 Subresource Integrity value"
    end

    identities = @icons.map do |icon|
      unless icon.keys.sort == %w[name weight]
        raise "Every Phosphor icon must contain only name and weight"
      end
      unless icon.fetch("name").match?(/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/)
        raise "Invalid Phosphor icon name: #{icon.fetch("name").inspect}"
      end
      unless ALLOWED_WEIGHTS.include?(icon.fetch("weight"))
        raise "Unsupported Phosphor icon weight: #{icon.fetch("weight").inspect}"
      end

      [icon.fetch("name"), icon.fetch("weight")]
    end

    duplicate = identities.tally.find { |_, count| count > 1 }
    raise "Duplicate Phosphor icon: #{duplicate.first.join(" ")}" if duplicate
  end

  def download_archive
    uri = URI.parse(@package.fetch("tarball"))
    response = Net::HTTP.get_response(uri)
    unless response.is_a?(Net::HTTPSuccess)
      raise "Unable to download Phosphor package: HTTP #{response.code}"
    end

    response.body
  end

  def verify_archive_integrity!(archive)
    actual = "sha512-#{Base64.strict_encode64(Digest::SHA512.digest(archive))}"
    expected = @package.fetch("integrity")
    raise "Phosphor package integrity mismatch" unless actual == expected
  end

  def archive_entries(archive)
    entries = {}
    gzip = Zlib::GzipReader.new(StringIO.new(archive))
    Gem::Package::TarReader.new(gzip) do |tar|
      tar.each do |entry|
        entries[entry.full_name] = entry.read if entry.file?
      end
    end
    entries
  ensure
    gzip&.close
  end

  def write_icon(icon, source, source_path)
    asset_name = asset_name(icon)
    directory = File.join(ASSET_ROOT, "#{asset_name}.imageset")
    filename = "#{asset_name}.svg"
    svg = source.sub("<svg ", "<svg width=\"16\" height=\"16\" ")
      .gsub("currentColor", "#000000")
    svg = "#{svg.rstrip}\n"

    FileUtils.mkdir_p(directory)
    File.write(File.join(directory, filename), svg)
    File.write(File.join(directory, "Contents.json"), formatted_json(imageset_contents(filename)))

    {
      "name" => icon.fetch("name"),
      "weight" => icon.fetch("weight"),
      "asset_name" => asset_name,
      "source_path" => source_path,
      "sha256" => Digest::SHA256.hexdigest(svg)
    }
  end

  def remove_unlisted_assets(asset_names)
    expected_directories = asset_names.map { |name| File.join(ASSET_ROOT, "#{name}.imageset") }
    Dir.glob(File.join(ASSET_ROOT, "*.imageset")).each do |directory|
      FileUtils.rm_rf(directory) unless expected_directories.include?(directory)
    end
  end

  def check_group_contents(errors)
    path = File.join(ASSET_ROOT, "Contents.json")
    actual = read_json(path, errors)
    errors << "Phosphor asset group metadata is stale" if actual && actual != group_contents
  end

  def check_license(lock, errors)
    unless File.file?(LICENSE_PATH)
      errors << "Missing Phosphor MIT license"
      return
    end
    return unless lock

    actual = Digest::SHA256.file(LICENSE_PATH).hexdigest
    errors << "Phosphor license checksum does not match the lock file" if actual != lock["license_sha256"]
  end

  def check_icons(lock, errors)
    return unless lock

    expected_package = @package.slice("name", "version", "integrity")
    errors << "Phosphor lock package metadata is stale" if lock["package"] != expected_package

    locked_icons = Array(lock["icons"])
    expected_asset_names = @icons.map { |icon| asset_name(icon) }
    locked_asset_names = locked_icons.map { |icon| icon["asset_name"] }
    errors << "Phosphor lock icon list is stale" if locked_asset_names != expected_asset_names

    @icons.each do |icon|
      name = asset_name(icon)
      locked = locked_icons.find { |candidate| candidate["asset_name"] == name }
      unless locked
        errors << "Missing lock entry for #{name}"
        next
      end

      expected_source_path = source_path(icon)
      errors << "Unexpected source path for #{name}" if locked["source_path"] != expected_source_path

      directory = File.join(ASSET_ROOT, "#{name}.imageset")
      filename = "#{name}.svg"
      svg_path = File.join(directory, filename)
      contents_path = File.join(directory, "Contents.json")

      unless File.file?(svg_path)
        errors << "Missing generated SVG for #{name}"
        next
      end
      actual_sha256 = Digest::SHA256.file(svg_path).hexdigest
      errors << "Generated SVG checksum mismatch for #{name}" if actual_sha256 != locked["sha256"]

      contents = read_json(contents_path, errors)
      if contents && contents != imageset_contents(filename)
        errors << "Asset metadata is stale for #{name}"
      end
    end

    actual_asset_names = Dir.glob(File.join(ASSET_ROOT, "*.imageset"))
      .map { |path| File.basename(path, ".imageset") }
      .sort
    unless actual_asset_names == expected_asset_names.sort
      errors << "Phosphor asset catalog contains unlisted image sets"
    end
  end

  def check_source_policy(errors)
    symbol_violations = self.class.source_policy_violations(root: ROOT, allowlist: SF_SYMBOL_ALLOWLIST)
    unless symbol_violations.empty?
      errors << "Unapproved SF Symbols are not allowed: #{symbol_violations.join(", ")}"
    end

    assets_root = File.join(ROOT, "Putio", "Assets.xcassets")
    legacy_assets = Dir.glob(File.join(assets_root, "*.imageset")).select do |path|
      name = File.basename(path, ".imageset")
      (name.start_with?("icon") && name != "iconOffline") || %w[chevronLeft eye].include?(name)
    end
    tabbar_assets = File.join(assets_root, "tabbarIcons")
    legacy_assets << tabbar_assets if Dir.exist?(tabbar_assets)
    unless legacy_assets.empty?
      errors << "Legacy icon catalogs are not allowed: #{legacy_assets.map { |path| relative(path) }.join(", ")}"
    end
  end

  def read_json(path, errors)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    errors << "Missing #{relative(path)}"
    nil
  rescue JSON::ParserError
    errors << "Invalid JSON in #{relative(path)}"
    nil
  end

  def source_path(icon)
    name = icon.fetch("name")
    weight = icon.fetch("weight")
    filename = weight == "regular" ? "#{name}.svg" : "#{name}-#{weight}.svg"
    "package/assets/#{weight}/#{filename}"
  end

  def asset_name(icon)
    "#{icon.fetch("name")}-#{icon.fetch("weight")}"
  end

  def group_contents
    {
      "info" => { "author" => "xcode", "version" => 1 },
      "properties" => { "provides-namespace" => true }
    }
  end

  def imageset_contents(filename)
    {
      "images" => [{ "filename" => filename, "idiom" => "universal" }],
      "info" => { "author" => "xcode", "version" => 1 },
      "properties" => {
        "preserves-vector-representation" => true,
        "template-rendering-intent" => "template"
      }
    }
  end

  def formatted_json(value)
    "#{JSON.pretty_generate(value)}\n"
  end

  def relative(path)
    path.delete_prefix("#{ROOT}/")
  end
end

if $PROGRAM_NAME == __FILE__
  case ARGV
  when []
    PhosphorIconSync.new.sync
  when ["--check"]
    PhosphorIconSync.new.check
  else
    warn "Usage: ruby scripts/sync-phosphor-icons.rb [--check]"
    exit 2
  end
end
