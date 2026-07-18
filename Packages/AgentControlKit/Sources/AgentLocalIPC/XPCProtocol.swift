#if os(macOS)
    import Foundation

    @objc(AgentControlXPCMessage)
    public final class XPCMessage: NSObject, NSSecureCoding, @unchecked Sendable {
        public static let supportsSecureCoding = true
        public let data: Data

        public init(data: Data) throws {
            guard data.count <= LocalIPCContract.maximumFrameSize else { throw LocalIPCError.oversizedFrame(data.count) }
            self.data = data
            super.init()
        }

        public convenience init(request: HelperRequest) throws {
            try self.init(data: JSONEncoder().encode(request))
        }

        public convenience init(response: HelperResponse) throws {
            try self.init(data: JSONEncoder().encode(response))
        }

        public required init?(coder: NSCoder) {
            guard let data = coder.decodeObject(of: NSData.self, forKey: "data") as Data?,
                  data.count <= LocalIPCContract.maximumFrameSize
            else { return nil }
            self.data = data
            super.init()
        }

        public func encode(with coder: NSCoder) {
            coder.encode(data as NSData, forKey: "data")
        }

        public func decodeRequest() throws -> HelperRequest {
            try JSONDecoder().decode(HelperRequest.self, from: data)
        }

        public func decodeResponse() throws -> HelperResponse {
            try JSONDecoder().decode(HelperResponse.self, from: data)
        }
    }

    @objc public protocol HelperXPCServiceProtocol {
        func request(_ message: XPCMessage, withReply reply: @escaping (XPCMessage) -> Void)
        func subscribe(withReply reply: @escaping (Bool) -> Void)
    }

    @objc public protocol HelperXPCEventSinkProtocol {
        func receive(_ message: XPCMessage)
    }

    public enum XPCInterfaces {
        public static func service() -> NSXPCInterface {
            NSXPCInterface(with: HelperXPCServiceProtocol.self)
        }

        public static func eventSink() -> NSXPCInterface {
            NSXPCInterface(with: HelperXPCEventSinkProtocol.self)
        }
    }
#endif
