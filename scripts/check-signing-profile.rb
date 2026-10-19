#!/usr/bin/env ruby
# frozen_string_literal: true

# Picks, from `asc profiles list --output json`, an App Store profile that signs
# <bundle-id> for <team-id> with the certificate whose DER SHA-256 is
# <certificate-sha256> and has not expired. Writes it to <output> and prints its
# UUID; with no such profile, says why each candidate for the app was refused.
# Ruby rather than Node: the archive jobs already have it for CocoaPods.
#
#   ruby scripts/check-signing-profile.rb <profiles.json> <certificate-sha256> <bundle-id> <team-id> <output>

require "json"
require "openssl"
require "rexml/document"
require "time"

def fail!(message)
  warn "check-signing-profile: #{message}"
  exit 1
end

def plist_value(node)
  case node.name
  when "dict"
    node.elements.to_a.each_slice(2).to_h { |key, value| [key.text.to_s, plist_value(value)] }
  when "array" then node.elements.map { |element| plist_value(element) }
  when "data" then node.text.to_s.unpack1("m")
  when "date" then Time.iso8601(node.text.to_s)
  when "true" then true
  when "false" then false
  when "integer" then Integer(node.text.to_s)
  else node.text.to_s
  end
end

def read_profile(der)
  pkcs7 = OpenSSL::PKCS7.new(der)
  # Only the payload is wanted: the profile came from App Store Connect over
  # TLS, and Apple's signing chain is not in the runner's trust store.
  pkcs7.verify([], OpenSSL::X509::Store.new, nil, OpenSSL::PKCS7::NOVERIFY)
  root = REXML::Document.new(pkcs7.data.to_s).root&.elements&.first
  raise ArgumentError, "no property list" unless root&.name == "dict"

  plist_value(root)
end

# Returns why the profile can't sign this build, or nil when it can.
def refusal(profile, certificate_sha256, bundle_id, team_id)
  entitlements = profile["Entitlements"] || {}
  # Older App IDs carry a prefix other than the team ID, so the bundle ID is
  # matched under the profile's own prefix and the team checked on its own.
  applications = Array(profile["ApplicationIdentifierPrefix"]).map { |prefix| "#{prefix}.#{bundle_id}" }
  return "is for #{entitlements['application-identifier'].inspect}" unless applications.include?(entitlements["application-identifier"])
  return "belongs to another team" unless Array(profile["TeamIdentifier"]).include?(team_id)
  return "lists devices, so it is not an App Store profile" if profile.key?("ProvisionedDevices")
  return "allows debugging, so it is not an App Store profile" if entitlements["get-task-allow"] == true

  expiration = profile["ExpirationDate"]
  return "expired at #{expiration.inspect}" unless expiration.is_a?(Time) && expiration > Time.now

  fingerprints = Array(profile["DeveloperCertificates"]).map { |der| OpenSSL::Digest::SHA256.hexdigest(der) }
  return "does not include certificate #{certificate_sha256}" unless fingerprints.include?(certificate_sha256)
  return "has no UUID" unless profile["UUID"].to_s.match?(/\A[0-9A-Fa-f-]{36}\z/)

  nil
end

fail!("usage: check-signing-profile.rb <profiles.json> <certificate-sha256> <bundle-id> <team-id> <output>") unless ARGV.length == 5
listing, certificate_sha256, bundle_id, team_id, output = ARGV
certificate_sha256 = certificate_sha256.downcase

begin
  resources = JSON.parse(File.read(listing)).fetch("data")
rescue JSON::ParserError, KeyError, SystemCallError => e
  fail!("cannot read #{listing}: #{e.message}")
end

refusals = []
matches = Array(resources).filter_map do |resource|
  attributes = (resource.is_a?(Hash) && resource["attributes"].is_a?(Hash)) ? resource["attributes"] : {}
  label = attributes["name"] || (resource["id"] if resource.is_a?(Hash)) || "profile"
  der = attributes["profileContent"].to_s.unpack1("m")
  begin
    profile = read_profile(der)
  rescue OpenSSL::PKCS7::PKCS7Error, REXML::ParseException, ArgumentError => e
    refusals << "#{label}: unreadable (#{e.message})"
    next
  end
  reason = refusal(profile, certificate_sha256, bundle_id, team_id)
  # Profiles for the team's other apps are expected and not worth a line.
  refusals << "#{label}: #{reason}" if reason && !reason.start_with?("is for ")
  [profile, der] unless reason
end

if matches.empty?
  refusals.each { |line| warn "  #{line}" }
  fail!("no active App Store profile signs #{bundle_id} with certificate #{certificate_sha256}")
end

# Any match signs the build; the one that lasts longest is the least surprising.
profile, der = matches.max_by { |match, _| match["ExpirationDate"] }
File.binwrite(output, der)
puts profile["UUID"]
