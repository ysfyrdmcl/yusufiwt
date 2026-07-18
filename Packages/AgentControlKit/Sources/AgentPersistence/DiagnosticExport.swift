import AgentDomain
import Foundation

public enum DiagnosticExportError: Error, Sendable, Equatable {
    case encodingFailed
}

public enum DiagnosticFeedbackError: Error, Sendable, Equatable {
    case consentRequired
    case invalidApplicationIdentity
    case packagingFailed
}

public struct DiagnosticFeedbackConsent: Sendable, Equatable {
    public let confirmed: Bool
    public let includePrivateMetadata: Bool

    public init(confirmed: Bool, includePrivateMetadata: Bool = false) {
        self.confirmed = confirmed
        self.includePrivateMetadata = includePrivateMetadata
    }
}

public enum RedactedDiagnosticExporter {
    public static func export(
        report: DiagnosticsReport,
        attachments: [DiagnosticAttachment] = [],
        includePrivateMetadata: Bool = false
    ) throws -> Data {
        let safeAttachments = attachments.map { attachment -> ExportAttachment in
            guard attachment.privacyClass == .publicMetadata
                || (attachment.privacyClass == .privateMetadata && includePrivateMetadata)
            else {
                return ExportAttachment(name: sanitize(attachment.name), content: "[redacted by privacy policy]")
            }
            return ExportAttachment(name: sanitize(attachment.name), content: sanitize(attachment.content))
        }
        let safeReport = ExportReport(
            formatVersion: 1,
            generatedAt: report.generatedAt,
            checks: report.checks.map {
                DiagnosticCheck(id: sanitize($0.id), status: $0.status, safeSummary: sanitize($0.safeSummary))
            },
            activeSessionCount: report.activeSessionCount,
            persistedEventCount: report.persistedEventCount,
            schemaVersion: report.schemaVersion,
            attachments: safeAttachments
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(safeReport)
    }

    public static func sanitize(_ input: String) -> String {
        var output = String(input.prefix(8192))
        let patterns = [
            #"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)\b(api[_-]?key|token|password|secret|authorization)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)(https?://[^\s?]+\?[^\s]*)(token|key|secret|password)=[^&\s]+"#,
            #"\b[A-Za-z0-9+/=_-]{32,}\b"#,
            #"/Users/[^/\s]+"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex ..< output.endIndex, in: output)
            output = expression.stringByReplacingMatches(
                in: output, options: [], range: range,
                withTemplate: pattern.hasPrefix("/Users") ? "~" : "[redacted]"
            )
        }
        return output
    }
}

/// Builds a reviewable, redacted file for user-initiated support submission.
/// It performs no network request and never includes sensitive or secret attachments.
public enum DiagnosticFeedbackPackageBuilder {
    public static func make(
        report: DiagnosticsReport,
        attachments: [DiagnosticAttachment] = [],
        summary: String,
        consent: DiagnosticFeedbackConsent,
        applicationVersion: String,
        buildNumber: String,
        supportID: UUID = UUID(),
        createdAt: Date = Date()
    ) throws -> Data {
        guard consent.confirmed else { throw DiagnosticFeedbackError.consentRequired }
        guard !applicationVersion.isEmpty, !buildNumber.isEmpty else {
            throw DiagnosticFeedbackError.invalidApplicationIdentity
        }
        do {
            let diagnosticData = try RedactedDiagnosticExporter.export(
                report: report,
                attachments: attachments,
                includePrivateMetadata: consent.includePrivateMetadata
            )
            let diagnostics = try JSONSerialization.jsonObject(with: diagnosticData)
            let formatter = ISO8601DateFormatter()
            let package: [String: Any] = [
                "formatVersion": 1,
                "supportID": supportID.uuidString.lowercased(),
                "createdAt": formatter.string(from: createdAt),
                "applicationVersion": RedactedDiagnosticExporter.sanitize(applicationVersion),
                "buildNumber": RedactedDiagnosticExporter.sanitize(buildNumber),
                "summary": RedactedDiagnosticExporter.sanitize(summary),
                "privateMetadataIncluded": consent.includePrivateMetadata,
                "diagnostics": diagnostics
            ]
            return try JSONSerialization.data(withJSONObject: package, options: [.prettyPrinted, .sortedKeys])
        } catch let error as DiagnosticFeedbackError {
            throw error
        } catch {
            throw DiagnosticFeedbackError.packagingFailed
        }
    }
}

private struct ExportAttachment: Codable {
    let name: String
    let content: String
}

private struct ExportReport: Codable {
    let formatVersion: Int
    let generatedAt: Date
    let checks: [DiagnosticCheck]
    let activeSessionCount: Int
    let persistedEventCount: Int
    let schemaVersion: Int
    let attachments: [ExportAttachment]
}
