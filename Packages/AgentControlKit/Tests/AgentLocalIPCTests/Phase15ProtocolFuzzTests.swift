#if os(macOS)
    import AgentLocalIPC
    import Foundation
    import Testing

    @Suite("Phase 15 protocol malformed corpus")
    struct Phase15ProtocolFuzzTests {
        @Test("Deterministic random frames never crash the decoder")
        func randomFrameCorpus() {
            var generator = Phase15Generator(state: 0xA63E_15F0_5EED)
            var accepted = 0
            for _ in 0 ..< 2000 {
                let length = Int(generator.next() % 1024)
                let data = Data((0 ..< length).map { _ in UInt8(truncatingIfNeeded: generator.next()) })
                if (try? SocketFrameCodec.decode(data)) != nil {
                    accepted += 1
                }
            }
            #expect(accepted == 0)
        }

        @Test("Every protected byte mutation is rejected")
        func mutationCorpus() throws {
            let frame = try SocketFrameCodec.encode(.init(messageType: .request, payload: Data("phase-15".utf8)))
            for index in frame.indices {
                var mutated = frame
                mutated[index] ^= 0x80
                #expect(throws: (any Error).self) {
                    try SocketFrameCodec.decode(mutated)
                }
            }
        }
    }

    private struct Phase15Generator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }
#endif
