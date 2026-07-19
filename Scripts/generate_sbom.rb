#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

root = File.expand_path("..", __dir__)
release_version = ENV.fetch("RELEASE_VERSION", "1.0.0-rc")
lockfile = File.join(root, "Services/AgentControlRelay/Package.resolved")
pins = JSON.parse(File.read(lockfile)).fetch("pins")
components = pins.sort_by { |pin| pin.fetch("identity") }.map do |pin|
  state = pin.fetch("state")
  version = state["version"] || state.fetch("revision")
  {
    "type" => "library",
    "bom-ref" => "pkg:swift/#{pin.fetch('identity')}@#{version}",
    "name" => pin.fetch("identity"),
    "version" => version,
    "purl" => "pkg:swift/#{pin.fetch('identity')}@#{version}",
    "externalReferences" => [{ "type" => "vcs", "url" => pin.fetch("location") }],
    "properties" => [{ "name" => "agentcontrol:revision", "value" => state.fetch("revision") }]
  }
end

project_spec = File.read(File.join(root, "project.yml"))
sparkle_version = project_spec.match(/Sparkle:\s*\n\s+url: https:\/\/github\.com\/sparkle-project\/Sparkle\s*\n\s+exactVersion: ([0-9.]+)/)&.captures&.first
raise "project.yml must pin Sparkle with exactVersion" unless sparkle_version

components << {
  "type" => "library",
  "bom-ref" => "pkg:swift/sparkle@#{sparkle_version}",
  "name" => "sparkle",
  "version" => sparkle_version,
  "purl" => "pkg:swift/sparkle@#{sparkle_version}",
  "externalReferences" => [{ "type" => "vcs", "url" => "https://github.com/sparkle-project/Sparkle" }]
}
components.sort_by! { |component| component.fetch("name") }

bom = {
  "bomFormat" => "CycloneDX",
  "specVersion" => "1.5",
  "version" => 1,
  "metadata" => {
    "component" => {
      "type" => "application",
      "bom-ref" => "pkg:generic/yusufiwt@#{release_version}",
      "name" => "yusufiwt",
      "version" => release_version
    }
  },
  "components" => components
}

puts JSON.pretty_generate(bom)
