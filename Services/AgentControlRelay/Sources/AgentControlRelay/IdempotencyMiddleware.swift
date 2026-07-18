import Crypto
import Foundation
import Vapor

struct CachedMutationResponse: Sendable {
    let statusCode: Int
    let headers: HTTPHeaders
    let body: Data?
    let expiresAt: Date

    func response() -> Response {
        Response(
            status: HTTPStatus(statusCode: statusCode),
            headers: headers,
            body: body.map { Response.Body(data: $0) } ?? .empty
        )
    }
}

actor MutationIdempotencyStore {
    enum BeginResult: Sendable { case cached(CachedMutationResponse), acquired, alreadyInFlight }
    private var responses: [String: CachedMutationResponse] = [:]
    private var inFlight: Set<String> = []

    func begin(_ key: String, now: Date) -> BeginResult {
        responses = responses.filter { $0.value.expiresAt > now }
        guard !inFlight.contains(key) else { return .alreadyInFlight }
        if let cached = responses[key] {
            return .cached(cached)
        }
        inFlight.insert(key)
        return .acquired
    }

    func finish(_ key: String, response: Response, now: Date) {
        inFlight.remove(key)
        guard (200 ..< 300).contains(Int(response.status.code)) else { return }
        responses[key] = .init(
            statusCode: Int(response.status.code), headers: response.headers, body: response.body.data,
            expiresAt: now.addingTimeInterval(86400)
        )
        if responses.count > 10000, let oldest = responses.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            responses.removeValue(forKey: oldest)
        }
    }

    func cancel(_ key: String) {
        inFlight.remove(key)
    }
}

struct MutationIdempotencyMiddleware: AsyncMiddleware {
    let store: MutationIdempotencyStore

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard [.POST, .PUT, .PATCH, .DELETE].contains(request.method),
              let clientKey = request.headers.first(name: "Idempotency-Key"),
              !clientKey.isEmpty, clientKey.count <= 200
        else { return try await next.respond(to: request) }
        let body = request.body.data.map { Data($0.readableBytesView) } ?? Data()
        let digest = Data(SHA256.hash(data: body)).base64URLEncodedString()
        let scope = "\(request.method.rawValue)|\(request.url.path)|\(clientKey)|\(digest)"
        switch await store.begin(scope, now: Date()) {
        case let .cached(cached): return cached.response()
        case .alreadyInFlight: throw Abort(.conflict, reason: "Mutation with this idempotency key is in progress")
        case .acquired: break
        }
        do {
            let response = try await next.respond(to: request)
            await store.finish(scope, response: response, now: Date())
            return response
        } catch {
            await store.cancel(scope)
            throw error
        }
    }
}
