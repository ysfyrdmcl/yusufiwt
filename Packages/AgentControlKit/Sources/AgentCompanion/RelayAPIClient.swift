#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation

public enum RelayClientError: Error, Sendable {
    case invalidResponse
    case rejected(Int)
}

public actor RelayAPIClient {
    private let baseURL: URL
    private let session: URLSession
    private var accessToken: String

    public init(baseURL: URL, accessToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL; self.accessToken = accessToken; self.session = session
    }

    public func updateAccessToken(_ token: String) {
        accessToken = token
    }

    public func submit(_ envelope: SealedRelayEnvelope, idempotencyKey: UUID = UUID()) async throws {
        var request = try makeRequest(path: "v1/envelopes", method: "POST")
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.httpBody = try CompanionCoding.makeEncoder().encode(envelope)
        _ = try await perform(request, accepted: 200 ..< 300)
    }

    public func pending(after cursor: UInt64) async throws -> (envelopes: [SealedRelayEnvelope], cursor: UInt64) {
        let data = try await perform(
            makeRequest(path: "v1/envelopes/pending?after=\(cursor)", method: "GET"), accepted: 200 ..< 300
        )
        return try CompanionCoding.makeDecoder().decode(PendingResponse.self, from: data).tuple
    }

    public func acknowledge(_ envelopeID: UUID, idempotencyKey: UUID = UUID()) async throws {
        var request = try makeRequest(path: "v1/envelopes/\(envelopeID.uuidString.lowercased())/ack", method: "POST")
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        _ = try await perform(request, accepted: 200 ..< 300)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else { throw RelayClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func perform(_ request: URLRequest, accepted: Range<Int>) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayClientError.invalidResponse }
        guard accepted.contains(http.statusCode) else { throw RelayClientError.rejected(http.statusCode) }
        return data
    }

    private struct PendingResponse: Decodable {
        let envelopes: [SealedRelayEnvelope]
        let cursor: UInt64
        var tuple: (envelopes: [SealedRelayEnvelope], cursor: UInt64) {
            (envelopes, cursor)
        }
    }
}
