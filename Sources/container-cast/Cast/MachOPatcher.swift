import Foundation

/// Patches a Mach-O binary after payload data has been appended:
/// 1. Removes the stale LC_CODE_SIGNATURE load command (decrements ncmds)
/// 2. Extends __LINKEDIT segment to cover the full file
/// This lets codesign treat the binary as unsigned and sign it fresh.
enum MachOPatcher {
    private static let MH_MAGIC_64: UInt32 = 0xFEED_FACF
    private static let LC_SEGMENT_64: UInt32 = 0x19
    private static let LC_CODE_SIGNATURE: UInt32 = 0x1D
    private static let pageSize: UInt64 = 16384  // arm64

    static func prepareForSigning(at url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        handle.seek(toFileOffset: 0)

        // mach_header_64: magic(4) cputype(4) cpusubtype(4) filetype(4) ncmds(4) sizeofcmds(4) flags(4) reserved(4)
        let header = handle.readData(ofLength: 32)
        guard header.count == 32 else { return }

        let magic = header.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magic == MH_MAGIC_64 else { return }

        let ncmds = header.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self) }

        var linkeditOffset: UInt64?
        var codesigOffset: UInt64?
        var codesigCmdsize: UInt32 = 0

        // Walk load commands
        var offset: UInt64 = 32
        for _ in 0..<ncmds {
            handle.seek(toFileOffset: offset)
            let cmdHeader = handle.readData(ofLength: 8)
            guard cmdHeader.count == 8 else { break }

            let cmd = cmdHeader.withUnsafeBytes { $0.load(as: UInt32.self) }
            let cmdsize = cmdHeader.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }

            if cmd == LC_SEGMENT_64 {
                handle.seek(toFileOffset: offset + 8)
                let nameData = handle.readData(ofLength: 16)
                let name = String(bytes: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
                if name == "__LINKEDIT" {
                    linkeditOffset = offset
                }
            } else if cmd == LC_CODE_SIGNATURE {
                codesigOffset = offset
                codesigCmdsize = cmdsize
            }

            offset += UInt64(cmdsize)
        }

        // 1. Zero out LC_CODE_SIGNATURE and decrement ncmds
        if let csOff = codesigOffset {
            handle.seek(toFileOffset: csOff)
            handle.write(Data(count: Int(codesigCmdsize)))

            // Decrement ncmds in header
            handle.seek(toFileOffset: 16)
            var newNcmds = (ncmds - 1).littleEndian
            handle.write(Data(bytes: &newNcmds, count: 4))

            // Decrement sizeofcmds
            let sizeOfCmds = header.withUnsafeBytes { $0.load(fromByteOffset: 20, as: UInt32.self) }
            var newSizeOfCmds = (sizeOfCmds - codesigCmdsize).littleEndian
            handle.seek(toFileOffset: 20)
            handle.write(Data(bytes: &newSizeOfCmds, count: 4))
        }

        // 2. Extend __LINKEDIT to cover the full file
        if let leOff = linkeditOffset {
            handle.seek(toFileOffset: leOff + 40)
            let fileoffData = handle.readData(ofLength: 8)
            let fileoff = fileoffData.withUnsafeBytes { $0.load(as: UInt64.self) }

            let newFilesize = fileSize - fileoff
            let newVmsize = (newFilesize + pageSize - 1) & ~(pageSize - 1)

            handle.seek(toFileOffset: leOff + 32)
            var vmsizeLE = newVmsize.littleEndian
            handle.write(Data(bytes: &vmsizeLE, count: 8))

            handle.seek(toFileOffset: leOff + 48)
            var filesizeLE = newFilesize.littleEndian
            handle.write(Data(bytes: &filesizeLE, count: 8))
        }
    }
}
