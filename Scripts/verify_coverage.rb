#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"

report_path = ARGV.fetch(0)
files = JSON.parse(File.read(report_path)).fetch("data").first.fetch("files")
domain_files = files.select { |file| file.fetch("filename").include?("/Sources/AgentDomain/") }
abort "AgentDomain coverage data is missing" if domain_files.empty?

line_counts = domain_files.map { |file| file.fetch("summary").fetch("lines") }
total = line_counts.sum { |lines| lines.fetch("count") }
covered = line_counts.sum { |lines| lines.fetch("covered") }
percentage = total.zero? ? 0.0 : covered.fdiv(total) * 100

risk = domain_files.find { |file| file.fetch("filename").end_with?("/Policies/RiskClassifier.swift") }
risk_percentage = risk&.fetch("summary")&.fetch("lines")&.fetch("percent") || 0.0

abort format("AgentDomain line coverage %.2f%% is below 90%%", percentage) if percentage < 90
abort format("RiskClassifier line coverage %.2f%% is below 100%%", risk_percentage) if risk_percentage < 100

puts format("AgentDomain coverage: %.2f%%; RiskClassifier: %.2f%%", percentage, risk_percentage)

