#if os(macOS)
    import CryptoKit
    import Foundation

    public enum SocketFrameCodec {
        public static let headerSize = 44

        public static func encode(_ frame: SocketFrame) throws -> Data {
            guard frame.payload.count <= LocalIPCContract.maximumFrameSize else {
                throw LocalIPCError.oversizedFrame(frame.payload.count)
            }
            var data = Data()
            data.append(LocalIPCContract.magic)
            data.appendUInt16(frame.protocolVersion)
            data.appendUInt16(frame.messageType.rawValue)
            data.appendUInt32(UInt32(frame.payload.count))
            data.append(contentsOf: SHA256.hash(data: frame.payload))
            data.append(frame.payload)
            return data
        }

        public static func decode(_ data: Data) throws -> SocketFrame {
            guard data.count >= headerSize else { throw LocalIPCError.truncatedFrame }
            guard data.prefix(4) == LocalIPCContract.magic else { throw LocalIPCError.invalidMagic }
            let version = data.uint16(at: 4)
            guard version == LocalIPCContract.currentVersion else { throw LocalIPCError.unsupportedVersion(version) }
            guard let messageType = SocketMessageType(rawValue: data.uint16(at: 6)) else {
                throw LocalIPCError.malformedPayload
            }
            let payloadSize = Int(data.uint32(at: 8))
            guard payloadSize <= LocalIPCContract.maximumFrameSize else { throw LocalIPCError.oversizedFrame(payloadSize) }
            let expectedSize = headerSize + payloadSize
            guard data.count >= expectedSize else { throw LocalIPCError.truncatedFrame }
            guard data.count == expectedSize else { throw LocalIPCError.trailingBytes }
            let checksum = data[12 ..< headerSize]
            let payload = data[headerSize ..< expectedSize]
            guard Data(checksum) == Data(SHA256.hash(data: payload)) else { throw LocalIPCError.checksumMismatch }
            return SocketFrame(protocolVersion: version, messageType: messageType, payload: Data(payload))
        }
    }

    private extension Data {
        mutating func appendUInt16(_ value: UInt16) {
            append(UInt8((value >> 8) & 0xFF))
            append(UInt8(value & 0xFF))
        }

        mutating func appendUInt32(_ value: UInt32) {
            append(UInt8((value >> 24) & 0xFF))
            append(UInt8((value >> 16) & 0xFF))
            append(UInt8((value >> 8) & 0xFF))
            append(UInt8(value & 0xFF))
        }

        func uint16(at index: Int) -> UInt16 {
            (UInt16(self[index]) << 8) | UInt16(self[index + 1])
        }

        func uint32(at index: Int) -> UInt32 {
            (UInt32(self[index]) << 24) |
                (UInt32(self[index + 1]) << 16) |
                (UInt32(self[index + 2]) << 8) |
                UInt32(self[index + 3])
        }
    }
#endif
