import Foundation
import os

/// Assembles the output binary: runner executable + kernel + initfs + rootfs + metadata + trailer.
struct PayloadWriter {
    private let log = Logger(subsystem: "com.containerfiles.container-cast", category: "payload-writer")

    struct Input {
        let runnerBinary: URL
        let kernel: URL
        let initfs: URL
        let rootfs: URL
        let metadata: PayloadMetadata
    }

    /// Write the assembled binary to the output path.
    func write(input: Input, to output: URL) throws {
        log.info("Assembling payload to \(output.path, privacy: .public)")

        let fm = FileManager.default
        if fm.fileExists(atPath: output.path) {
            try fm.removeItem(at: output)
        }

        // Start with the runner binary
        try fm.copyItem(at: input.runnerBinary, to: output)

        let handle = try FileHandle(forWritingTo: output)
        defer { handle.closeFile() }

        // Seek to end of runner binary
        handle.seekToEndOfFile()
        let kernelOffset = handle.offsetInFile

        // Append kernel
        let kernelSize = try appendFile(input.kernel, to: handle)
        let initfsOffset = handle.offsetInFile

        // Append initfs (sparse-aware)
        let initfsSize = try appendSparseFile(input.initfs, to: handle)
        let rootfsOffset = handle.offsetInFile

        // Append rootfs (sparse-aware)
        let rootfsSize = try appendSparseFile(input.rootfs, to: handle)

        // Append metadata JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadataData = try encoder.encode(input.metadata)
        handle.write(metadataData)

        // Append trailer
        let trailer = PayloadTrailer(
            kernelOffset: kernelOffset,
            kernelSize: UInt64(kernelSize),
            initfsOffset: initfsOffset,
            initfsSize: UInt64(initfsSize),
            rootfsOffset: rootfsOffset,
            rootfsSize: UInt64(rootfsSize)
        )
        handle.write(trailer.encode())

        // Make executable
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: output.path
        )

        let totalSize = handle.offsetInFile
        log.info("Payload written: \(totalSize) bytes")
    }

    /// Append a file's contents in chunks (dense copy). Returns bytes written.
    private func appendFile(_ url: URL, to handle: FileHandle) throws -> Int {
        let reader = try FileHandle(forReadingFrom: url)
        defer { reader.closeFile() }

        var written = 0
        let chunkSize = 8 * 1024 * 1024  // 8 MB

        while true {
            let data = reader.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            handle.write(data)
            written += data.count
        }

        return written
    }

    /// Append a potentially-sparse ext4 file, compacting it by recording
    /// only non-zero blocks. The runner reconstructs the sparse layout on extraction.
    ///
    /// Format:
    ///   [8] total_file_size (logical size for sparse reconstruction)
    ///   [8] region_count
    ///   [16 * N] (offset, size) pairs for each non-zero region
    ///   [data bytes for each region]
    private func appendSparseFile(_ url: URL, to handle: FileHandle) throws -> Int {
        let reader = try FileHandle(forReadingFrom: url)
        defer { reader.closeFile() }

        let fileSize = reader.seekToEndOfFile()
        reader.seek(toFileOffset: 0)

        // Scan the file to find non-zero regions.
        // Read in 4 KB blocks (ext4 block size) and merge consecutive non-zero blocks into regions.
        let blockSize = 4096
        var regions: [(offset: UInt64, size: UInt64)] = []
        var currentRegionStart: UInt64?
        var currentRegionEnd: UInt64 = 0
        var pos: UInt64 = 0

        let zeroBlock = Data(count: blockSize)

        while pos < fileSize {
            let toRead = min(UInt64(blockSize), fileSize - pos)
            let block = reader.readData(ofLength: Int(toRead))
            if block.isEmpty { break }

            let isZero = (block.count == blockSize) ? (block == zeroBlock) : block.allSatisfy({ $0 == 0 })

            if !isZero {
                if currentRegionStart != nil {
                    currentRegionEnd = pos + UInt64(block.count)
                } else {
                    // Start new region
                    currentRegionStart = pos
                    currentRegionEnd = pos + UInt64(block.count)
                }
            } else {
                // Zero block — close any open region
                if let start = currentRegionStart {
                    regions.append((offset: start, size: currentRegionEnd - start))
                    currentRegionStart = nil
                }
            }

            pos += UInt64(block.count)
        }

        // Close final region
        if let start = currentRegionStart {
            regions.append((offset: start, size: currentRegionEnd - start))
        }

        let dataBytes = regions.reduce(UInt64(0)) { $0 + $1.size }
        log.info("Sparse compact: \(fileSize) logical -> \(dataBytes) data (\(regions.count) regions)")

        // Write header
        let headerStart = handle.offsetInFile
        var totalFileSizeLE = fileSize.littleEndian
        var regionCountLE = UInt64(regions.count).littleEndian
        handle.write(Data(bytes: &totalFileSizeLE, count: 8))
        handle.write(Data(bytes: &regionCountLE, count: 8))

        for region in regions {
            var offLE = region.offset.littleEndian
            var szLE = region.size.littleEndian
            handle.write(Data(bytes: &offLE, count: 8))
            handle.write(Data(bytes: &szLE, count: 8))
        }

        // Write data for each region
        let chunkSize = 8 * 1024 * 1024
        for region in regions {
            reader.seek(toFileOffset: region.offset)
            var remaining = region.size
            while remaining > 0 {
                let toRead = Int(min(UInt64(chunkSize), remaining))
                let data = reader.readData(ofLength: toRead)
                guard !data.isEmpty else { break }
                handle.write(data)
                remaining -= UInt64(data.count)
            }
        }

        return Int(handle.offsetInFile - headerStart)
    }
}
