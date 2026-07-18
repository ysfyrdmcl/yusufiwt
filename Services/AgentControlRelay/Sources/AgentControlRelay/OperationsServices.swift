import Crypto
import Foundation
import Vapor

public struct EmergencyDisablePolicy: Sendable, Equatable {
    public let pairing: Bool
    public let envelopeSubmission: Bool
    public let apns: Bool
    public let liveActivities: Bool

    public init(environment: [String: String]) {
        func enabled(_ name: String) -> Bool {
            guard let value = environment[name]?.lowercased() else { return false }
            return value == "1" || value == "true" || value == "yes"
        }
        pairing = enabled("EMERGENCY_DISABLE_PAIRING")
        envelopeSubmission = enabled("EMERGENCY_DISABLE_ENVELOPE_SUBMISSION")
        apns = enabled("EMERGENCY_DISABLE_APNS")
        liveActivities = enabled("EMERGENCY_DISABLE_LIVE_ACTIVITIES")
    }
}

public enum APNSMetricChannel: String, Sendable {
    case notification
    case liveActivity = "live_activity"
}

public actor RelayOperationalMetrics {
    private var requestsByStatusClass: [String: UInt64] = [:]
    private var apnsDeliveries: [String: UInt64] = [:]

    public init() {}

    public func recordRequest(statusCode: Int) {
        let label = "\(max(0, statusCode) / 100)xx"
        requestsByStatusClass[label, default: 0] += 1
    }

    public func recordAPNS(_ result: APNSDeliveryResult, channel: APNSMetricChannel) {
        let resultLabel = switch result {
        case .accepted: "accepted"
        case .invalidToken: "invalid_token"
        case .retryable: "retryable"
        case .permanentFailure: "permanent_failure"
        }
        apnsDeliveries["\(channel.rawValue)|\(resultLabel)", default: 0] += 1
    }

    public func prometheusSnapshot() -> String {
        var lines = [
            "# HELP agentcontrol_relay_http_requests_total Relay HTTP responses by bounded status class.",
            "# TYPE agentcontrol_relay_http_requests_total counter"
        ]
        for label in requestsByStatusClass.keys.sorted() {
            lines.append("agentcontrol_relay_http_requests_total{status_class=\"\(label)\"} \(requestsByStatusClass[label, default: 0])")
        }
        lines += [
            "# HELP agentcontrol_relay_apns_delivery_total APNs delivery outcomes using bounded non-identifying labels.",
            "# TYPE agentcontrol_relay_apns_delivery_total counter"
        ]
        for key in apnsDeliveries.keys.sorted() {
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            lines.append("agentcontrol_relay_apns_delivery_total{channel=\"\(parts[0])\",result=\"\(parts[1])\"} \(apnsDeliveries[key, default: 0])")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct OperationalMetricsMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            let response = try await next.respond(to: request)
            await request.application.operationalMetrics.recordRequest(statusCode: Int(response.status.code))
            return response
        } catch {
            let status = (error as? any AbortError)?.status.code ?? 500
            await request.application.operationalMetrics.recordRequest(statusCode: Int(status))
            throw error
        }
    }
}

struct MetricsAccessPolicy: Sendable {
    private let expectedDigest: Data?

    init(token: String?) {
        expectedDigest = token.map { Data(SHA256.hash(data: Data($0.utf8))) }
    }

    var isEnabled: Bool {
        expectedDigest != nil
    }

    func authorizes(_ token: String) -> Bool {
        guard let expectedDigest else { return false }
        let provided = Data(SHA256.hash(data: Data(token.utf8)))
        guard expectedDigest.count == provided.count else { return false }
        return zip(expectedDigest, provided).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

private struct OperationalMetricsKey: StorageKey { typealias Value = RelayOperationalMetrics }
private struct EmergencyDisablePolicyKey: StorageKey { typealias Value = EmergencyDisablePolicy }
private struct MetricsAccessPolicyKey: StorageKey { typealias Value = MetricsAccessPolicy }

extension Application {
    var operationalMetrics: RelayOperationalMetrics {
        get {
            guard let value = storage[OperationalMetricsKey.self] else {
                preconditionFailure("Operational metrics were not installed")
            }
            return value
        }
        set { storage[OperationalMetricsKey.self] = newValue }
    }

    var emergencyDisablePolicy: EmergencyDisablePolicy {
        get {
            guard let value = storage[EmergencyDisablePolicyKey.self] else {
                preconditionFailure("Emergency disable policy was not installed")
            }
            return value
        }
        set { storage[EmergencyDisablePolicyKey.self] = newValue }
    }

    var metricsAccessPolicy: MetricsAccessPolicy {
        get {
            guard let value = storage[MetricsAccessPolicyKey.self] else {
                preconditionFailure("Metrics access policy was not installed")
            }
            return value
        }
        set { storage[MetricsAccessPolicyKey.self] = newValue }
    }
}

func configureOperationalMetrics(on application: Application) {
    guard application.metricsAccessPolicy.isEnabled else { return }
    application.get("internal", "metrics") { request async throws -> Response in
        guard let bearer = request.headers.bearerAuthorization,
              application.metricsAccessPolicy.authorizes(bearer.token)
        else { throw Abort(.unauthorized) }
        let body = await application.operationalMetrics.prometheusSnapshot()
        var headers = HTTPHeaders()
        headers.contentType = .init(type: "text", subType: "plain", parameters: ["version": "0.0.4"])
        headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        return Response(status: .ok, headers: headers, body: .init(string: body))
    }
}
