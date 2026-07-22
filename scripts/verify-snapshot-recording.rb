#!/usr/bin/env ruby

# Reads `xcresulttool get test-results tests` JSON on stdin and exits nonzero
# if the run contains any failure other than the intentional record-mode
# snapshot assertions, so `make screenshots-record` cannot report success
# after a crash or partial walk.

require "json"

ACCEPTED = /Record mode is on|No reference was found on disk/

def walk(nodes, &block)
  nodes.each do |node|
    block.call(node)
    walk(node["children"] || [], &block)
  end
end

data = JSON.parse($stdin.read)
unexpected = []

walk(data["testNodes"] || []) do |node|
  next unless node["nodeType"] == "Failure Message"
  next if node["name"].to_s.match?(ACCEPTED)

  unexpected << node["name"]
end

unless unexpected.empty?
  warn "Unexpected failures during snapshot recording:"
  unexpected.each { |message| warn "  #{message}" }
  exit 1
end
