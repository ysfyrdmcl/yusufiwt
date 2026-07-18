import AgentLocalIPC
import Foundation
import Testing

@Suite("Unix socket frame codec")
struct SocketFrameCodecTests {
    @Test("Frame round trips with version, type, length, and checksum")
    func roundTrip() throws {
        let original = SocketFrame(messageType: .request, payload: Data("hello".utf8))
        #expect(try SocketFrameCodec.decode(SocketFrameCodec.encode(original)) == original)
    }

    @Test("Malformed, tampered, truncated, trailing, future, and oversized frames fail closed")
    func malformedFrames() throws {
        let valid = try SocketFrameCodec.encode(SocketFrame(messageType: .request, payload: Data("hello".utf8)))
        var invalidMagic = valid
        invalidMagic[0] = 0
        #expect(throws: LocalIPCError.invalidMagic) { try SocketFrameCodec.decode(invalidMagic) }

        var tampered = valid
        tampered[tampered.count - 1] ^= 0xFF
        #expect(throws: LocalIPCError.checksumMismatch) { try SocketFrameCodec.decode(tampered) }
        #expect(throws: LocalIPCError.truncatedFrame) { try SocketFrameCodec.decode(Data(valid.dropLast())) }
        #expect(throws: LocalIPCError.trailingBytes) { try SocketFrameCodec.decode(valid + Data([0])) }

        var future = valid
        future[4] = 0
        future[5] = 2
        #expect(throws: LocalIPCError.unsupportedVersion(2)) { try SocketFrameCodec.decode(future) }

        let oversized = SocketFrame(
            messageType: .request,
            payload: Data(repeating: 0, count: LocalIPCContract.maximumFrameSize + 1)
        )
        #expect(throws: LocalIPCError.oversizedFrame(LocalIPCContract.maximumFrameSize + 1)) {
            try SocketFrameCodec.encode(oversized)
        }
    }
}
