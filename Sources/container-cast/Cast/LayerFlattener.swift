import Containerization
import ContainerizationArchive
import ContainerizationOCI
import Foundation

/// Flattens all OCI image layers into a single tar archive with whiteouts resolved.
///
/// The multi-layer EXT4 unpack path in Apple's Containerization framework calls
/// `EXT4.Formatter.unlink()` to process OCI whiteout entries. Certain combinations of
/// cross-layer deletions corrupt the EXT4 image, causing VMs to crash on boot.
///
/// By flattening layers into a single tar first, whiteouts are resolved during flattening
/// and the EXT4 formatter only ever sees creates — never deletes.
struct LayerFlattener {

    /// Flatten all layers of `image` for `platform` into a single uncompressed tar at `output`.
    /// Returns the cumulative uncompressed data size (for EXT4 sizing).
    func flatten(image: Containerization.Image, platform: Platform, to output: URL) async throws -> UInt64 {
        let manifest = try await image.manifest(for: platform)

        // Final filesystem state: path → index into entries array
        var pathIndex: [String: Int] = [:]
        var entries: [(WriteEntry, Data)] = []

        for layer in manifest.layers {
            let content = try await image.getContent(digest: layer.digest)

            let filter: ContainerizationArchive.Filter
            switch layer.mediaType {
            case MediaTypes.imageLayer, MediaTypes.dockerImageLayer:
                filter = .none
            case MediaTypes.imageLayerGzip, MediaTypes.dockerImageLayerGzip:
                filter = .gzip
            case MediaTypes.imageLayerZstd, MediaTypes.dockerImageLayerZstd:
                filter = .zstd
            default:
                filter = .gzip
            }

            let reader = try ArchiveReader(format: .paxRestricted, filter: filter, file: content.path)
            for (entry, data) in reader {
                guard let entryPath = entry.path else { continue }

                let basename = (entryPath as NSString).lastPathComponent
                let parent = (entryPath as NSString).deletingLastPathComponent

                if basename == ".wh..wh..opq" {
                    // Opaque whiteout: remove all children of the parent directory
                    let prefix = parent.hasSuffix("/") ? parent : parent + "/"
                    let toRemove = pathIndex.keys.filter { $0.hasPrefix(prefix) && $0 != parent && $0 != prefix }
                    for path in toRemove {
                        pathIndex.removeValue(forKey: path)
                    }
                    continue
                }

                if basename.hasPrefix(".wh.") {
                    // Single-entry whiteout: remove the named path and any children
                    let targetName = String(basename.dropFirst(4))
                    let targetPath = parent.isEmpty ? targetName : parent + "/" + targetName
                    pathIndex.removeValue(forKey: targetPath)
                    // Also remove children if it was a directory
                    let childPrefix = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
                    let toRemove = pathIndex.keys.filter { $0.hasPrefix(childPrefix) }
                    for path in toRemove {
                        pathIndex.removeValue(forKey: path)
                    }
                    continue
                }

                // Regular entry: add or overwrite
                if let existing = pathIndex[entryPath] {
                    entries[existing] = (entry, data)
                } else {
                    pathIndex[entryPath] = entries.count
                    entries.append((entry, data))
                }
            }
        }

        // Write surviving entries to output tar
        let writer = try ArchiveWriter(format: .paxRestricted, filter: .none, file: output)
        var totalSize: UInt64 = 0

        // Collect surviving indices and sort by original insertion order
        let surviving = pathIndex.values.sorted()
        for index in surviving {
            let (entry, data) = entries[index]
            try writer.writeEntry(entry: entry, data: data)
            totalSize += UInt64(data.count)
        }

        return totalSize
    }
}
