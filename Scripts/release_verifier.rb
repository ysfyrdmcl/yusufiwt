#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "open3"
require "optparse"
require "pathname"
require "time"

class VerificationError < StandardError; end

class ReleaseVerifier
  def initialize(root:, require_notarization: false)
    @root = Pathname(root)
    @require_notarization = require_notarization
    @checks = []
  end

  attr_reader :checks

  def structural!
    required = %w[
      Config/ExportOptions/DeveloperID.plist
      Config/ExportOptions/AppStoreExport.plist
      Config/ExportOptions/TestFlightUpload.plist
      Config/Updates/channels.json
      Scripts/release_macos.sh
      Scripts/release_ios.sh
      Docs/RELEASE_RUNBOOK.md
    ]
    required.each { |path| assert(@root.join(path).file?, "required file exists: #{path}") }

    release_config = @root.join("Config/Release.xcconfig").read
    assert(release_config.include?("ENABLE_HARDENED_RUNTIME = YES"), "Release enables Hardened Runtime")
    assert(release_config.include?("DEBUG_INFORMATION_FORMAT = dwarf-with-dsym"), "Release emits dSYMs")

    channels = JSON.parse(@root.join("Config/Updates/channels.json").read).fetch("channels")
    assert(channels.keys.sort == %w[beta stable], "stable and beta update channels are declared")
    channels.each_value do |channel|
      assert(channel.fetch("appcastURL").start_with?("https://"), "appcast URL uses HTTPS")
      assert(channel.fetch("downloadURLPrefix").start_with?("https://"), "download URL uses HTTPS")
    end

    Dir[@root.join("Config/ExportOptions/*.plist")].each do |plist|
      run!("/usr/bin/plutil", "-lint", plist)
    end
    project = @root.join("project.yml").read
    assert(project.include?("exactVersion: 2.9.2"), "Sparkle version is pinned")
    assert(project.include?("release-manifest.json"), "helper compatibility manifest is generated")
  end

  def mac_app!(app_path:, dmg_path: nil, sbom_path: nil, checksums_path: nil, dsym_path: nil)
    app = Pathname(app_path).expand_path
    assert(app.directory? && app.extname == ".app", "macOS app bundle exists")
    info = plist_json(app.join("Contents/Info.plist"))
    assert(info.fetch("CFBundleIdentifier") == "com.yusuf.agentcontrol.mac", "macOS bundle identifier matches")
    assert(info.fetch("CFBundleVersion").match?(/\A[1-9][0-9]*\z/), "build number is a positive integer")
    assert(info.fetch("SUFeedURL").start_with?("https://"), "embedded Sparkle feed uses HTTPS")
    key = Base64.strict_decode64(info.fetch("SUPublicEDKey"))
    assert(key.bytesize == 32, "embedded Sparkle Ed25519 public key is 32 bytes")

    manifest = JSON.parse(app.join("Contents/Resources/release-manifest.json").read)
    assert(manifest.fetch("schemaVersion") == 1, "release manifest schema is supported")
    assert(manifest.fetch("marketingVersion") == info.fetch("CFBundleShortVersionString"), "manifest marketing version matches")
    assert(manifest.fetch("buildNumber").to_s == info.fetch("CFBundleVersion"), "manifest build number matches")
    assert(manifest.fetch("localProtocolVersion") == 1, "app/helper local protocol is compatible")
    %w[helper hook].each do |component|
      entry = manifest.fetch(component)
      executable = app.join(entry.fetch("path"))
      assert(executable.file?, "#{component} is embedded")
      assert(Digest::SHA256.file(executable).hexdigest == entry.fetch("sha256"), "#{component} digest matches manifest")
      run!("/usr/bin/codesign", "--verify", "--strict", "--verbose=2", executable.to_s)
    end

    run!("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app.to_s)
    signature = run!("/usr/bin/codesign", "-dvv", app.to_s, combine: true)
    assert(signature.include?("Developer ID Application:"), "app uses Developer ID Application signing")
    assert(signature.match?(/flags=.*runtime/), "code signature has Hardened Runtime")
    entitlements = run!("/usr/bin/codesign", "-d", "--entitlements", ":-", app.to_s, combine: true)
    assert(!entitlements.match?(%r{<key>com\.apple\.security\.get-task-allow</key>\s*<true/>}), "get-task-allow is disabled")
    run!("/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app.to_s)

    if @require_notarization
      run!("/usr/bin/xcrun", "stapler", "validate", app.to_s)
      if dmg_path
        run!("/usr/bin/xcrun", "stapler", "validate", Pathname(dmg_path).expand_path.to_s)
        run!("/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=2", Pathname(dmg_path).expand_path.to_s)
      end
    end

    verify_sbom!(sbom_path, info.fetch("CFBundleShortVersionString")) if sbom_path
    verify_checksums!(checksums_path) if checksums_path
    verify_dsyms!(app, dsym_path) if dsym_path
  rescue ArgumentError => error
    raise VerificationError, "invalid Sparkle public key: #{error.message}"
  end

  def ios_archive!(archive_path:)
    archive = Pathname(archive_path).expand_path
    app = archive.join("Products/Applications/yusufiwt.app")
    assert(app.directory?, "iOS application exists in archive")
    info = plist_json(app.join("Info.plist"))
    assert(info.fetch("CFBundleIdentifier") == "com.yusuf.agentcontrol.ios", "iOS bundle identifier matches")
    assert(info.fetch("CFBundleVersion").match?(/\A[1-9][0-9]*\z/), "iOS build number is a positive integer")
    run!("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app.to_s)
    entitlements = plist_from_codesign(app)
    assert(entitlements.fetch("aps-environment") == "production", "iOS archive uses production APNs")
    assert(Array(entitlements["com.apple.developer.applesignin"]).include?("Default"), "Sign in with Apple entitlement exists")
    assert(Array(entitlements["com.apple.security.application-groups"]).include?("group.com.yusuf.agentcontrol"), "app group entitlement exists")
    assert(Array(entitlements["keychain-access-groups"]).any? { |group| group.end_with?("com.yusuf.agentcontrol.companion.shared") }, "shared keychain entitlement exists")

    expected_suffixes = %w[NotificationService.appex AgentLiveActivity.appex AgentWidgets.appex]
    plugins = Dir[app.join("PlugIns/*.appex")]
    expected_suffixes.each { |suffix| assert(plugins.any? { |path| path.end_with?(suffix) }, "#{suffix} is embedded") }
    assert(!Dir[app.join("Watch/*.app")].empty?, "watchOS app is embedded")
    assert(!Dir[archive.join("dSYMs/*.dSYM")].empty?, "archive retains dSYMs")
  end

  private

  def verify_sbom!(path, version)
    sbom = JSON.parse(Pathname(path).expand_path.read)
    assert(sbom.fetch("bomFormat") == "CycloneDX", "SBOM is CycloneDX")
    assert(sbom.dig("metadata", "component", "version") == version, "SBOM version matches app")
  end

  def verify_checksums!(path)
    checksum_path = Pathname(path).expand_path
    run!("/usr/bin/shasum", "-a", "256", "-c", checksum_path.basename.to_s, chdir: checksum_path.dirname.to_s)
    @checks << "artifact checksums match"
  end

  def verify_dsyms!(app, path)
    dsym = Pathname(path).expand_path
    assert(dsym.exist?, "dSYM artifact exists")
    return unless dsym.directory?

    app_uuids = run!("/usr/bin/dwarfdump", "--uuid", app.join("Contents/MacOS/yusufiwt").to_s).lines.map { |line| line.split[1] }.compact
    dsym_uuids = Dir[dsym.join("**/Contents/Resources/DWARF/*")].flat_map do |binary|
      run!("/usr/bin/dwarfdump", "--uuid", binary).lines.map { |line| line.split[1] }.compact
    end
    assert(!(app_uuids & dsym_uuids).empty?, "app binary UUID has a retained dSYM")
  end

  def plist_json(path)
    JSON.parse(run!("/usr/bin/plutil", "-convert", "json", "-o", "-", path.to_s))
  end

  def plist_from_codesign(path)
    output = run!("/usr/bin/codesign", "-d", "--entitlements", ":-", path.to_s, combine: true)
    xml_start = output.index("<?xml") || output.index("<plist")
    raise VerificationError, "codesign returned no entitlements for #{path}" unless xml_start

    stdout, stderr, status = Open3.capture3("/usr/bin/plutil", "-convert", "json", "-o", "-", "-", stdin_data: output[xml_start..])
    raise VerificationError, "unable to parse entitlements: #{stderr}" unless status.success?

    JSON.parse(stdout)
  end

  def assert(condition, message)
    raise VerificationError, message unless condition

    @checks << message
  end

  def run!(*command, combine: false, chdir: nil)
    spawn_options = chdir ? { chdir: chdir } : {}
    stdout, stderr, status = Open3.capture3(*command, **spawn_options)
    output = combine ? stdout + stderr : stdout
    raise VerificationError, "command failed: #{command.join(' ')}\n#{stderr}" unless status.success?

    output
  end
end

options = { root: File.expand_path("..", __dir__), require_notarization: false }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: release_verifier.rb [--structural | --app PATH | --ios-archive PATH]"
  opts.on("--structural") { options[:structural] = true }
  opts.on("--app PATH") { |value| options[:app] = value }
  opts.on("--dmg PATH") { |value| options[:dmg] = value }
  opts.on("--sbom PATH") { |value| options[:sbom] = value }
  opts.on("--checksums PATH") { |value| options[:checksums] = value }
  opts.on("--dsyms PATH") { |value| options[:dsyms] = value }
  opts.on("--ios-archive PATH") { |value| options[:ios_archive] = value }
  opts.on("--require-notarization") { options[:require_notarization] = true }
  opts.on("--report PATH") { |value| options[:report] = value }
end
parser.parse!

begin
  verifier = ReleaseVerifier.new(root: options[:root], require_notarization: options[:require_notarization])
  if options[:structural]
    verifier.structural!
  elsif options[:app]
    verifier.mac_app!(app_path: options[:app], dmg_path: options[:dmg], sbom_path: options[:sbom], checksums_path: options[:checksums], dsym_path: options[:dsyms])
  elsif options[:ios_archive]
    verifier.ios_archive!(archive_path: options[:ios_archive])
  else
    raise VerificationError, "choose --structural, --app, or --ios-archive"
  end

  result = { status: "passed", verifiedAt: Time.now.utc.iso8601, checks: verifier.checks }
  File.write(options[:report], JSON.pretty_generate(result) + "\n") if options[:report]
  puts "release verifier: #{verifier.checks.length} checks passed"
rescue VerificationError, KeyError, JSON::ParserError => error
  warn "release verifier failed: #{error.message}"
  exit 1
end
