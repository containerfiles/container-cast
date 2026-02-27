import CryptoKit
import Foundation
import os

/// Reads the embedded payload from the runner's own executable and extracts to cache.
struct PayloadExtractor {
    private let log = Logger(subsystem: "com.containerfiles.container-cast", category: "extractor")

    static let cacheRoot = FileManager.default.urls(
        for: .cachesDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("com.containerfiles.container-cast")

    struct ExtractedPayload {
        let kernelPath: URL
        let initfsPath: URL
        let rootfsPath: URL
        let metadata: PayloadMetadata
    }

    /// Extract payload from the running binary, using cache when possible.
    func extract() throws -> ExtractedPayload {
        let execURL = Self.resolveExecutablePath()
        let handle = try FileHandle(forReadingFrom: execURL)
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > UInt64(PayloadTrailer.size) else {
            throw PayloadError.missingPayload
        }

        // Try reading trailer from EOF first (unsigned binary).
        // If that fails, the binary was codesigned after assembly — the code signature
        // sits after the trailer. Parse LC_CODE_SIGNATURE and scan backward for the magic.
        let trailerData: Data
        let trailerOffset: UInt64

        handle.seek(toFileOffset: fileSize - UInt64(PayloadTrailer.size))
        let eofCandidate = handle.readData(ofLength: PayloadTrailer.size)
        if Array(eofCandidate.prefix(8)) == PayloadTrailer.magic {
            trailerData = eofCandidate
            trailerOffset = fileSize - UInt64(PayloadTrailer.size)
        } else {
            (trailerData, trailerOffset) = try findTrailerBeforeCodeSignature(handle: handle)
        }
        let trailer = try PayloadTrailer.decode(from: trailerData)

        // Compute cache key from trailer bytes
        let cacheKey = SHA256.hash(data: trailerData)
            .map { String(format: "%02x", $0) }.joined()
        let cacheDir = Self.cacheRoot.appendingPathComponent(String(cacheKey.prefix(16)))

        // Always read metadata from the binary — it's tiny and the cache key
        // (trailer SHA256) doesn't cover it, so caching metadata causes stale reads
        // when the same image is recast with different flags.
        let metadataOffset = trailer.rootfsOffset + trailer.rootfsSize
        let metadataSize = trailerOffset - metadataOffset
        handle.seek(toFileOffset: metadataOffset)
        let metadataData = handle.readData(ofLength: Int(metadataSize))
        let metadata = try JSONDecoder().decode(PayloadMetadata.self, from: metadataData)

        let fm = FileManager.default
        let kernelPath = cacheDir.appendingPathComponent("vmlinux")
        let initfsPath = cacheDir.appendingPathComponent("initfs.ext4")
        let rootfsPath = cacheDir.appendingPathComponent("rootfs.ext4")

        // Check cache validity (heavy files only — kernel, initfs, rootfs)
        if fm.fileExists(atPath: kernelPath.path)
            && fm.fileExists(atPath: initfsPath.path)
            && fm.fileExists(atPath: rootfsPath.path)
        {
            log.info("Using cached payload at \(cacheDir.path, privacy: .public)")
            return ExtractedPayload(
                kernelPath: kernelPath,
                initfsPath: initfsPath,
                rootfsPath: rootfsPath,
                metadata: metadata
            )
        }

        // Extract fresh
        log.info("Extracting payload to \(cacheDir.path, privacy: .public)")
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        try extractChunk(
            handle: handle,
            offset: trailer.kernelOffset,
            size: trailer.kernelSize,
            to: kernelPath
        )
        try extractSparseChunk(
            handle: handle,
            offset: trailer.initfsOffset,
            size: trailer.initfsSize,
            to: initfsPath
        )

        // Rootfs uses sparse-aware format
        try extractSparseChunk(
            handle: handle,
            offset: trailer.rootfsOffset,
            size: trailer.rootfsSize,
            to: rootfsPath
        )

        return ExtractedPayload(
            kernelPath: kernelPath,
            initfsPath: initfsPath,
            rootfsPath: rootfsPath,
            metadata: metadata
        )
    }

    /// Extract a contiguous chunk from the payload.
    private func extractChunk(handle: FileHandle, offset: UInt64, size: UInt64, to dest: URL) throws {
        handle.seek(toFileOffset: offset)
        let chunkSize = 8 * 1024 * 1024  // 8 MB
        var remaining = size
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let output = try FileHandle(forWritingTo: dest)
        defer { output.closeFile() }

        while remaining > 0 {
            let toRead = Int(min(UInt64(chunkSize), remaining))
            let data = handle.readData(ofLength: toRead)
            guard !data.isEmpty else { break }
            output.write(data)
            remaining -= UInt64(data.count)
        }
    }

    /// Extract a sparse-format rootfs, reconstructing the sparse file layout.
    ///
    /// Format in payload:
    ///   [8] total_file_size
    ///   [8] region_count
    ///   [16 * N] (offset, size) pairs
    ///   [data for each region]
    private func extractSparseChunk(
        handle: FileHandle, offset: UInt64, size: UInt64, to dest: URL
    ) throws {
        handle.seek(toFileOffset: offset)

        // Read header
        let totalFileSizeData = handle.readData(ofLength: 8)
        let regionCountData = handle.readData(ofLength: 8)
        guard totalFileSizeData.count == 8, regionCountData.count == 8 else {
            throw PayloadError.extractionFailed("sparse header truncated")
        }

        let totalFileSize = UInt64(littleEndian: totalFileSizeData.withUnsafeBytes { $0.load(as: UInt64.self) })
        let regionCount = UInt64(littleEndian: regionCountData.withUnsafeBytes { $0.load(as: UInt64.self) })

        log.info("Sparse rootfs: \(totalFileSize) bytes, \(regionCount) regions")

        // Read region map
        var regions: [(offset: UInt64, size: UInt64)] = []
        for _ in 0..<regionCount {
            let regionData = handle.readData(ofLength: 16)
            guard regionData.count == 16 else {
                throw PayloadError.extractionFailed("sparse region map truncated")
            }
            let off = UInt64(littleEndian: regionData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt64.self) })
            let sz = UInt64(littleEndian: regionData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt64.self) })
            regions.append((offset: off, size: sz))
        }

        // Create sparse output file
        let fd = open(dest.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw PayloadError.extractionFailed("cannot create \(dest.path)")
        }
        defer { close(fd) }

        // Set the file to the full logical size (creates sparse file)
        guard ftruncate(fd, off_t(totalFileSize)) == 0 else {
            throw PayloadError.extractionFailed("cannot set file size to \(totalFileSize)")
        }

        // Write data regions at their correct offsets
        let chunkSize = 8 * 1024 * 1024
        for region in regions {
            lseek(fd, off_t(region.offset), SEEK_SET)
            var remaining = region.size
            while remaining > 0 {
                let toRead = Int(min(UInt64(chunkSize), remaining))
                let data = handle.readData(ofLength: toRead)
                guard !data.isEmpty else { break }
                try data.withUnsafeBytes { buf in
                    var written = 0
                    while written < data.count {
                        let result = write(fd, buf.baseAddress! + written, data.count - written)
                        if result < 0 {
                            if errno == EINTR { continue }
                            throw PayloadError.extractionFailed("write failed: \(String(cString: strerror(errno)))")
                        }
                        written += result
                    }
                }
                remaining -= UInt64(data.count)
            }
        }

        log.info("Sparse rootfs extracted: \(totalFileSize) logical, \(regions.count) data regions")
    }

    /// Resolve the absolute path of the running executable.
    /// argv[0] can be a bare name when invoked via PATH, so we resolve it properly.
    private static func resolveExecutablePath() -> URL {
        // _NSGetExecutablePath gives the real path on macOS
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var size = UInt32(buf.count)
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let path = buf.withUnsafeBufferPointer { ptr in
                String(decoding: ptr.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        // Fallback: resolve argv[0] against PATH
        let arg0 = CommandLine.arguments[0]
        if arg0.contains("/") {
            return URL(fileURLWithPath: arg0).standardizedFileURL
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = "\(dir)/\(arg0)"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate).standardizedFileURL
                }
            }
        }
        return URL(fileURLWithPath: arg0).standardizedFileURL
    }

    /// Find the payload trailer in a codesigned binary by parsing LC_CODE_SIGNATURE
    /// and scanning backward from its offset for the "CASTBIN\0" magic.
    private func findTrailerBeforeCodeSignature(handle: FileHandle) throws -> (Data, UInt64) {
        handle.seek(toFileOffset: 0)
        let header = handle.readData(ofLength: 32)
        guard header.count == 32 else { throw PayloadError.missingPayload }

        let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magic == 0xFEED_FACF else { throw PayloadError.missingPayload }

        let ncmds = header.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }

        // Find LC_CODE_SIGNATURE (cmd = 0x1D)
        var offset: UInt64 = 32
        var codesigOffset: UInt64?
        for _ in 0..<ncmds {
            handle.seek(toFileOffset: offset)
            let cmdHeader = handle.readData(ofLength: 8)
            guard cmdHeader.count == 8 else { break }

            let cmd = cmdHeader.withUnsafeBytes { $0.load(as: UInt32.self) }
            let cmdsize = cmdHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

            if cmd == 0x1D {
                // linkedit_data_command: cmd(4) cmdsize(4) dataoff(4) datasize(4)
                let rest = handle.readData(ofLength: 8)
                guard rest.count == 8 else { break }
                let dataoff = rest.withUnsafeBytes { $0.load(as: UInt32.self) }
                codesigOffset = UInt64(dataoff)
                break
            }

            offset += UInt64(cmdsize)
        }

        guard let boundary = codesigOffset else {
            throw PayloadError.missingPayload
        }

        // Scan backward from the code signature for the trailer magic.
        // The trailer is 56 bytes with "CASTBIN\0" at the start. Read a chunk
        // before the code signature and search backward within it.
        let searchSize = min(boundary, 1_048_576)  // max 1 MB scan
        let searchStart = boundary - searchSize
        handle.seek(toFileOffset: searchStart)
        let searchData = handle.readData(ofLength: Int(searchSize))

        let magicBytes = PayloadTrailer.magic
        let trailerSize = PayloadTrailer.size

        // Search backward for the magic
        var pos = searchData.count - trailerSize
        while pos >= 0 {
            if Array(searchData[pos..<(pos + 8)]) == magicBytes {
                let trailerData = Data(searchData[pos..<(pos + trailerSize)])
                let trailerFileOffset = searchStart + UInt64(pos)
                return (trailerData, trailerFileOffset)
            }
            pos -= 1
        }

        throw PayloadError.missingPayload
    }
}
