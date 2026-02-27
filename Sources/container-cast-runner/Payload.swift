// Duplicated in container-cast/Cast/Payload.swift — the runner must be
// self-contained (embedded in output binaries), so it can't share a library target.
// Keep both copies in sync.

import Foundation

/// Metadata baked into the payload, describing VM defaults and image config.
struct PayloadMetadata: Codable, Sendable {
    var name: String
    var entrypoint: [String]
    var cmd: [String]
    var env: [String]
    var workdir: String
    var cpus: Int
    var memory: Int
    var network: Bool
    var interactive: Bool
    var tty: Bool
}

/// Binary trailer appended after all payload data.
///
/// Layout (56 bytes, all little-endian):
/// ```
/// [8] magic:          "CASTBIN\0"
/// [8] kernel_offset:  UInt64
/// [8] kernel_size:    UInt64
/// [8] initfs_offset:  UInt64
/// [8] initfs_size:    UInt64
/// [8] rootfs_offset:  UInt64
/// [8] rootfs_size:    UInt64
/// ```
struct PayloadTrailer: Sendable {
    static let magic: [UInt8] = Array("CASTBIN\0".utf8)
    static let size = 56

    let kernelOffset: UInt64
    let kernelSize: UInt64
    let initfsOffset: UInt64
    let initfsSize: UInt64
    let rootfsOffset: UInt64
    let rootfsSize: UInt64

    func encode() -> Data {
        var data = Data(capacity: Self.size)
        data.append(contentsOf: Self.magic)
        data.appendLE(kernelOffset)
        data.appendLE(kernelSize)
        data.appendLE(initfsOffset)
        data.appendLE(initfsSize)
        data.appendLE(rootfsOffset)
        data.appendLE(rootfsSize)
        return data
    }

    static func decode(from data: Data) throws -> PayloadTrailer {
        guard data.count == size else {
            throw PayloadError.invalidTrailer("expected \(size) bytes, got \(data.count)")
        }
        let magicBytes = Array(data.prefix(8))
        guard magicBytes == magic else {
            throw PayloadError.invalidTrailer("bad magic")
        }
        return PayloadTrailer(
            kernelOffset: data.readLE(at: 8),
            kernelSize: data.readLE(at: 16),
            initfsOffset: data.readLE(at: 24),
            initfsSize: data.readLE(at: 32),
            rootfsOffset: data.readLE(at: 40),
            rootfsSize: data.readLE(at: 48)
        )
    }
}

enum PayloadError: LocalizedError {
    case invalidTrailer(String)
    case missingPayload
    case extractionFailed(String)
    case metadataCorrupted

    var errorDescription: String? {
        switch self {
        case .invalidTrailer(let detail): "Invalid payload trailer: \(detail)"
        case .missingPayload: "No embedded payload found in binary"
        case .extractionFailed(let detail): "Payload extraction failed: \(detail)"
        case .metadataCorrupted: "Embedded metadata is corrupted"
        }
    }
}

// MARK: - Data helpers

extension Data {
    mutating func appendLE(_ value: UInt64) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func readLE(at offset: Int) -> UInt64 {
        self.withUnsafeBytes { buf in
            buf.load(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }
}
