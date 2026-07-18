@testable import AgentControlRelay
import Testing

@Suite("Phase 17 relay operations")
struct Phase17OperationsTests {
    @Test("Emergency disable environment is fail-closed and independently scoped")
    func emergencyDisablePolicy() {
        let policy = EmergencyDisablePolicy(environment: [
            "EMERGENCY_DISABLE_PAIRING": "1",
            "EMERGENCY_DISABLE_APNS": "true",
            "EMERGENCY_DISABLE_ENVELOPE_SUBMISSION": "0",
        ])

        #expect(policy.pairing)
        #expect(policy.apns)
        #expect(!policy.envelopeSubmission)
        #expect(!policy.liveActivities)
    }

    @Test("Prometheus snapshot has bounded labels and no user data")
    func operationalMetrics() async {
        let metrics = RelayOperationalMetrics()
        await metrics.recordRequest(statusCode: 200)
        await metrics.recordRequest(statusCode: 503)
        await metrics.recordAPNS(.accepted, channel: .notification)
        await metrics.recordAPNS(.retryable, channel: .liveActivity)
        let snapshot = await metrics.prometheusSnapshot()

        #expect(snapshot.contains("agentcontrol_relay_http_requests_total{status_class=\"2xx\"} 1"))
        #expect(snapshot.contains("agentcontrol_relay_http_requests_total{status_class=\"5xx\"} 1"))
        #expect(snapshot.contains("agentcontrol_relay_apns_delivery_total{channel=\"notification\",result=\"accepted\"} 1"))
        #expect(snapshot.contains("agentcontrol_relay_apns_delivery_total{channel=\"live_activity\",result=\"retryable\"} 1"))
        #expect(!snapshot.contains("device_id"))
        #expect(!snapshot.contains("token"))
    }
}
