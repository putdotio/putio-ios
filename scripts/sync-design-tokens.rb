#!/usr/bin/env ruby

# Generates Xcode color assets and the UIColor.Putio API from the vendored
# design-system tokens. Mirrors the Phosphor icon sync pattern:
#
#   ruby scripts/sync-design-tokens.rb           # regenerate colorsets + Swift
#   ruby scripts/sync-design-tokens.rb --check   # fail on drift (verify gate)
#
# Token source: Config/DesignTokens.json — a generated mirror of the canonical
# design-system token build. Do not hand-edit values there or output here.

require "fileutils"
require "json"

class DesignTokenSync
  ROOT = File.expand_path("..", __dir__)
  TOKENS_PATH = File.join(ROOT, "Config", "DesignTokens.json")
  COLORS_ROOT = File.join(ROOT, "Putio", "Assets.xcassets", "Colors")
  SWIFT_PATH = File.join(ROOT, "Putio", "Common", "Extensions", "UIColor+Putio.swift")

  def initialize(check_only:)
    @check_only = check_only
    @tokens = JSON.parse(File.read(TOKENS_PATH))
    @drift = []
  end

  def run
    color_tokens = collect_color_tokens

    color_tokens.each do |token|
      write_colorset("putio.#{token.fetch(:group)}.#{token.fetch(:key)}", token)
    end

    remove_unlisted_colorsets(color_tokens)
    write_swift(color_tokens)

    if @check_only
      check_interface_builder_references(color_tokens)

      unless @drift.empty?
        warn "Design tokens are out of sync. Run: make tokens-sync"
        @drift.each { |path| warn "  drift: #{path}" }
        exit 1
      end
      puts "Verified #{color_tokens.size} design tokens."
    else
      puts "Generated #{color_tokens.size} colorsets and UIColor+Putio.swift."
    end
  end

  private

  # Swift misuse of a dropped token fails at compile time, but a storyboard/xib
  # namedColor reference to a token whose colorset was removed degrades
  # silently at runtime — gate those references here.
  def check_interface_builder_references(color_tokens)
    known = color_tokens.map { |t| "putio.#{t.fetch(:group)}.#{t.fetch(:key)}" }.to_set

    Dir.glob(File.join(ROOT, "Putio", "**", "*.{storyboard,xib}")).each do |path|
      File.read(path).scan(/name="(putio\.[^"]+)"/).flatten.uniq.each do |name|
        next if known.include?(name)

        @drift << "#{path.delete_prefix("#{ROOT}/")} references unknown color #{name}"
      end
    end
  end

  def collect_color_tokens
    tokens = []
    @tokens.each do |group, entries|
      next if group.start_with?("$")

      entries.each do |key, definition|
        next if key.start_with?("$")
        next unless definition.is_a?(Hash) && definition["$type"] == "color"
        next unless definition["$value"].to_s.start_with?("hsl")

        light = parse_hsl(definition.fetch("$value"))
        dark_raw = definition.dig("$extensions", "putio.mode", "dark")
        tokens << {
          group: group,
          key: key,
          light: light,
          dark: dark_raw ? parse_hsl(dark_raw) : light
        }
      end
    end
    tokens
  end

  def parse_hsl(value)
    match = value.match(/\Ahsla?\(\s*([\d.]+)\s*,\s*([\d.]+)%\s*,\s*([\d.]+)%\s*(?:,\s*([\d.]+)\s*)?\)\z/)
    raise "Unparseable color value: #{value.inspect}" unless match

    h = match[1].to_f
    s = match[2].to_f / 100.0
    l = match[3].to_f / 100.0
    alpha = (match[4] || "1").to_f

    c = (1 - (2 * l - 1).abs) * s
    x = c * (1 - ((h / 60.0) % 2 - 1).abs)
    m = l - c / 2.0

    r1, g1, b1 =
      case h
      when 0...60 then [c, x, 0]
      when 60...120 then [x, c, 0]
      when 120...180 then [0, c, x]
      when 180...240 then [0, x, c]
      when 240...300 then [x, 0, c]
      else [c, 0, x]
      end

    {
      red: format("%.3f", r1 + m),
      green: format("%.3f", g1 + m),
      blue: format("%.3f", b1 + m),
      alpha: format("%.3f", alpha)
    }
  end

  def colorset_contents(token)
    {
      "colors" => [
        color_entry(token.fetch(:light), appearances: nil),
        color_entry(token.fetch(:dark), appearances: [{ "appearance" => "luminosity", "value" => "dark" }])
      ],
      "info" => { "author" => "xcode", "version" => 1 }
    }
  end

  def color_entry(components, appearances:)
    entry = {}
    entry["appearances"] = appearances if appearances
    entry["color"] = {
      "color-space" => "srgb",
      "components" => {
        "alpha" => components.fetch(:alpha),
        "blue" => components.fetch(:blue),
        "green" => components.fetch(:green),
        "red" => components.fetch(:red)
      }
    }
    entry["idiom"] = "universal"
    entry
  end

  def write_colorset(name, token)
    dir = File.join(COLORS_ROOT, "#{name}.colorset")
    path = File.join(dir, "Contents.json")
    content = "#{JSON.pretty_generate(colorset_contents(token))}\n"
    write_output(path, content)
  end

  def remove_unlisted_colorsets(color_tokens)
    expected = color_tokens.map { |t| "putio.#{t.fetch(:group)}.#{t.fetch(:key)}.colorset" }

    Dir.glob(File.join(COLORS_ROOT, "*.colorset")).each do |dir|
      basename = File.basename(dir)
      next if expected.include?(basename)

      if @check_only
        @drift << dir
      else
        FileUtils.rm_rf(dir)
      end
    end
  end

  def swift_name(key)
    parts = key.split("-")
    name = parts[0] + parts[1..].map(&:capitalize).join
    name = "step#{name}" if name.match?(/\A\d/)
    name
  end

  def write_swift(color_tokens)
    groups = color_tokens.group_by { |t| t.fetch(:group) }

    lines = []
    lines << "import UIKit"
    lines << ""
    lines << "// Generated by scripts/sync-design-tokens.rb from Config/DesignTokens.json."
    lines << "// Do not edit; run `make tokens-sync` after token changes."
    lines << "extension UIColor {"
    lines << "    struct Putio {"

    groups.keys.sort.each do |group|
      struct_name = group.split("-").map(&:capitalize).join
      lines << "        struct #{struct_name} {"
      groups.fetch(group).sort_by { |t| t.fetch(:key) }.each do |token|
        asset = "putio.#{group}.#{token.fetch(:key)}"
        lines << "            static let #{swift_name(token.fetch(:key))} = UIColor(named: \"#{asset}\")!"
      end
      lines << "        }"
      lines << ""
    end

    lines << "    }"
    lines << "}"

    write_output(SWIFT_PATH, "#{lines.join("\n")}\n")
  end

  def write_output(path, content)
    if @check_only
      @drift << path unless File.exist?(path) && File.read(path) == content
    else
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end
end

DesignTokenSync.new(check_only: ARGV.include?("--check")).run
