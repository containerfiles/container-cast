import Foundation
import Testing

@testable import container_cast

@Suite("Payload trailer encoding/decoding")
struct PayloadTrailerTests {

    @Test("Round-trip encode/decode preserves values")
    func roundTrip() throws {
        let original = PayloadTrailer(
            kernelOffset: 1024,
            kernelSize: 50_000_000,
            initfsOffset: 50_001_024,
            initfsSize: 10_000_000,
            rootfsOffset: 60_001_024,
            rootfsSize: 200_000_000
        )

        let encoded = original.encode()
        #expect(encoded.count == PayloadTrailer.size)

        let decoded = try PayloadTrailer.decode(from: encoded)
        #expect(decoded.kernelOffset == original.kernelOffset)
        #expect(decoded.kernelSize == original.kernelSize)
        #expect(decoded.initfsOffset == original.initfsOffset)
        #expect(decoded.initfsSize == original.initfsSize)
        #expect(decoded.rootfsOffset == original.rootfsOffset)
        #expect(decoded.rootfsSize == original.rootfsSize)
    }

    @Test("Magic bytes are correct")
    func magicBytes() throws {
        let trailer = PayloadTrailer(
            kernelOffset: 0,
            kernelSize: 0,
            initfsOffset: 0,
            initfsSize: 0,
            rootfsOffset: 0,
            rootfsSize: 0
        )

        let encoded = trailer.encode()
        let magic = String(data: encoded.prefix(8), encoding: .utf8)
        #expect(magic == "CASTBIN\0")
    }

    @Test("Decode rejects wrong magic")
    func badMagic() {
        var data = Data(repeating: 0, count: 56)
        data.replaceSubrange(0..<8, with: "NOTRIGHT".utf8)

        #expect(throws: PayloadError.self) {
            try PayloadTrailer.decode(from: data)
        }
    }

    @Test("Decode rejects wrong size")
    func badSize() {
        let data = Data(repeating: 0, count: 40)

        #expect(throws: PayloadError.self) {
            try PayloadTrailer.decode(from: data)
        }
    }

    @Test("Handles large offsets (multi-GB binaries)")
    func largeOffsets() throws {
        let trailer = PayloadTrailer(
            kernelOffset: 5_000_000_000,
            kernelSize: 100_000_000,
            initfsOffset: 5_100_000_000,
            initfsSize: 50_000_000,
            rootfsOffset: 5_150_000_000,
            rootfsSize: 2_000_000_000
        )

        let decoded = try PayloadTrailer.decode(from: trailer.encode())
        #expect(decoded.kernelOffset == 5_000_000_000)
        #expect(decoded.rootfsSize == 2_000_000_000)
    }
}

@Suite("Payload metadata encoding")
struct PayloadMetadataTests {

    @Test("Metadata JSON round-trip")
    func roundTrip() throws {
        let original = PayloadMetadata(
            name: "test-app",
            entrypoint: ["/bin/sh", "-c"],
            cmd: ["echo", "hello"],
            env: ["PATH=/usr/bin", "HOME=/root"],
            workdir: "/app",
            cpus: 4,
            memory: 1024,
            network: true,
            interactive: true,
            tty: false
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(PayloadMetadata.self, from: data)

        #expect(decoded.name == "test-app")
        #expect(decoded.entrypoint == ["/bin/sh", "-c"])
        #expect(decoded.cmd == ["echo", "hello"])
        #expect(decoded.env == ["PATH=/usr/bin", "HOME=/root"])
        #expect(decoded.workdir == "/app")
        #expect(decoded.cpus == 4)
        #expect(decoded.memory == 1024)
        #expect(decoded.network == true)
        #expect(decoded.interactive == true)
        #expect(decoded.tty == false)
    }
}
