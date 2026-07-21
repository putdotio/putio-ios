#!/usr/bin/env ruby

# Reads `xcresulttool get test-results tests` JSON on stdin and exits nonzero
# if the run contains any failure other than the intentional record-mode
# snapshot assertions, so `make screenshots-record` cannot report success
# after a crash or partial walk.
#
# Fails closed: a payload with no test nodes (schema drift, empty bundle) or
# no record-mode assertions at all (record mode silently off) is an error,
# because this script is the only discriminator between "recorded cleanly"
# and "never actually recorded".

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
tests_seen = 0
recordings_seen = 0

walk(data["testNodes"] || []) do |node|
  tests_seen += 1 if node["nodeType"] == "Test Case"
  next unless node["nodeType"] == "Failure Message"

  if node["name"].to_s.match?(ACCEPTED)
    recordings_seen += 1
  else
    unexpected << node["name"]
  end
end

unless unexpected.empty?
  warn "Unexpected failures during snapshot recording:"
  unexpected.each { |message| warn "  #{message}" }
  exit 1
end

if tests_seen.zero?
  warn "No test cases found in the result payload; the run never executed tests (or the xcresulttool schema changed)."
  exit 1
end

if recordings_seen.zero?
  warn "No record-mode snapshot assertions found; record mode was not active, so no baselines were written."
  exit 1
end
