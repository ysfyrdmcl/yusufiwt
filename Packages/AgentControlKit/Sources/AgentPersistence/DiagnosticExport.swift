import AgentDomain
import Foundation

public enum DiagnosticExportError: Error, Sendable, Equatable {
    case encodingFailed
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
