#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"

class Phase17VerificationError < StandardError; end

class Phase17Verifier
  EXPECTED_FEATURES = %w[
    automatic_updates companion_relay companion_remote_decisions live_activities
    managed_codex provider_hooks push_notifications redacted_diagnostic_feedback
    watch_companion widgets
  ].freeze
  REQUIRED_ADAPTERS = %w[codex claude gemini].freeze
  REQUIRED_SIGNALS = %w[crash relay apns].freeze

  def initialize(root)
    @root = Pathname(root)
    @checks = []
  end

  attr_reader :checks

  def structural!
    required = %w[
      Config/Operations/internal-alpha.json
      Config/Operations/emergency-disable.json
      Config/Operations/adapter-compatibility.json
      Config/Operations/operations-dashboard.json
      Config/Operations/release-gate.json
      Config/Operations/release-evidence.example.json
      Docs/ADR/0021-beta-launch-operations.md
      Docs/ADAPTER_COMPATIBILITY.md
      Docs/BETA_RELEASE_NOTES.md
      Docs/KNOWN_ISSUES.md
      Docs/INCIDENT_RUNBOOK.md
      Docs/PRIVACY_POLICY.md
      Docs/SUPPORT.md
      Docs/DATA_DELETION.md
      Docs/RELEASE_CHECKLIST.md
      Docs/ROLLBACK_RUNBOOK.md
      Docs/PHASE_17_TEST_PLAN.md
      Services/AgentControlRelay/Sources/AgentControlRelay/OperationsServices.swift
    ]
    required.each { |path| assert(@root.join(path).file?, "required file exists: #{path}") }

    alpha = json("Config/Operations/internal-alpha.json")
    assert(alpha.fetch("schemaVersion") == 1, "feature schema is supported")
    assert(alpha.fetch("profile") == "internal_alpha", "internal alpha profile is explicit")
    assert(alpha.fetch("enabled").sort == EXPECTED_FEATURES.sort, "internal alpha feature set is complete")
    assert(alpha.fetch("emergencyDisabled").empty?, "alpha defaults do not silently disable features")

    emergency = json("Config/Operations/emergency-disable.json").fetch("flags")
    assert(emergency.all? { |flag| flag.fetch("default") == false }, "emergency flags default off")
    variables = emergency.map { |flag| flag.fetch("environmentVariable") }
    assert(variables.uniq.length == variables.length, "emergency flags have unique environment variables")

    compatibility = json("Config/Operations/adapter-compatibility.json")
    adapters = compatibility.fetch("adapters")
    assert((REQUIRED_ADAPTERS - adapters.map { |adapter| adapter.fetch("id") }).empty?, "Codex, Claude, and Gemini are published")
    assert(adapters.all? { |adapter| adapter.fetch("fallback") == "monitor_only" }, "unknown versions fail to monitor-only")
    assert(adapters.all? { |adapter| !adapter.fetch("evidence").empty? }, "every adapter has evidence")
    assert(compatibility.dig("localOnlyMode", "accountRequired") == false, "local-only mode requires no account")
    assert(compatibility.dig("localOnlyMode", "status") == "verified", "local-only mode is marked verified")

    dashboard = json("Config/Operations/operations-dashboard.json")
    signals = dashboard.fetch("panels").map { |panel| panel.fetch("signal") }.uniq
    assert((REQUIRED_SIGNALS - signals).empty?, "dashboard covers crash, relay, and APNs")
    assert(dashboard.fetch("panels").all? { |panel| panel.key?("warning") && panel.key?("critical") }, "every panel has thresholds")

    gates = json("Config/Operations/release-gate.json").fetch("gates")
    assert(gates.length == 8 && gates.all? { |gate| gate.fetch("required") }, "all 1.0 gates are mandatory")
    template = json("Config/Operations/release-evidence.example.json").fetch("gates")
    assert(template.map { |gate| gate.fetch("id") }.sort == gates.map { |gate| gate.fetch("id") }.sort, "evidence template matches release gates")
  end

  def release_evidence!(path)
    structural!
    evidence = JSON.parse(Pathname(path).read)
    expected = json("Config/Operations/release-gate.json").fetch("gates").map { |gate| gate.fetch("id") }.sort
    actual = evidence.fetch("gates").map { |gate| gate.fetch("id") }.sort
    assert(actual == expected, "release evidence covers the exact gate set")
    assert(evidence.fetch("gates").all? { |gate| gate.fetch("status") == "passed" }, "every release gate passed")
    assert(evidence.fetch("gates").all? { |gate| !gate.fetch("evidence").to_s.empty? }, "every release gate has evidence")
    assert(!evidence.fetch("releaseCommit").to_s.empty?, "release commit is recorded")
  rescue Errno::ENOENT, JSON::ParserError, KeyError => error
    raise Phase17VerificationError, "invalid release evidence: #{error.message}"
  end

  private

  def json(path)
    JSON.parse(@root.join(path).read)
  rescue JSON::ParserError, KeyError => error
    raise Phase17VerificationError, "invalid #{path}: #{error.message}"
  end

  def assert(condition, message)
    raise Phase17VerificationError, message unless condition

    @checks << message
  end
end

options = { root: File.expand_path("..", __dir__) }
OptionParser.new do |parser|
  parser.on("--structural") { options[:structural] = true }
  parser.on("--release-evidence PATH") { |value| options[:release_evidence] = value }
end.parse!

begin
  verifier = Phase17Verifier.new(options[:root])
  if options[:release_evidence]
    verifier.release_evidence!(options[:release_evidence])
  else
    verifier.structural!
  end
  puts "phase 17 verifier: #{verifier.checks.length} checks passed"
rescue Phase17VerificationError, Errno::ENOENT, JSON::ParserError, KeyError => error
  warn "phase 17 verifier failed: #{error.message}"
  exit 1
end
