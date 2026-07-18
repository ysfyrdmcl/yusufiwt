import AgentDomain
import AgentPersistence
import Foundation
import Testing

@Suite("Phase 17 redacted diagnostic feedback")
struct Phase17DiagnosticFeedbackTests {
    private let report = DiagnosticsReport(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        checks: [.init(id: "relay", status: .warning, safeSummary: "token=secret-value")],
        activeSessionCount: 1,
        persistedEventCount: 2,
        schemaVersion: 2
    )

    @Test("Feedback packaging requires explicit consent")
    func consentRequired() {
        #expect(throws: DiagnosticFeedbackError.consentRequired) {
            _ = try DiagnosticFeedbackPackageBuilder.make(
                report: report,
                summary: "Relay issue",
                consent: .init(confirmed: false),
                applicationVersion: "1.0.0",
                buildNumber: "1"
            )
        }
    }

    @Test("Feedback package redacts secrets and excludes private metadata by default")
    func packageIsRedacted() throws {
        let data = try DiagnosticFeedbackPackageBuilder.make(
            report: report,
            attachments: [
                .init(name: "public.log", content: "Authorization: token=top-secret", privacyClass: .publicMetadata),
                .init(name: "private.log", content: "/Users/alice/project", privacyClass: .privateMetadata),
                .init(name: "secret.log", content: "never-export", privacyClass: .secret),
            ],
            summary: "Failure for /Users/alice with api_key=top-secret",
            consent: .init(confirmed: true),
            applicationVersion: "1.0.0",
            buildNumber: "1",
            supportID: UUID(uuidString: "00000000-0000-0000-0000-000000000017")!,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        let text = try #require(String(data: data, encoding: .utf8))

        #expect(text.contains("00000000-0000-0000-0000-000000000017"))
        #expect(text.contains("[redacted]"))
        #expect(text.contains("[redacted by privacy policy]"))
        #expect(!text.contains("alice"))
        #expect(!text.contains("top-secret"))
        #expect(!text.contains("never-export"))
    }
}
