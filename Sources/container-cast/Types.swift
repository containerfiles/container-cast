import ArgumentParser
import Foundation

/// Parses human-readable memory sizes: 512M, 1G, 2048 (bare number = MB).
struct MemorySize: ExpressibleByArgument, CustomStringConvertible {
    let megabytes: Int

    init?(argument: String) {
        let upper = argument.uppercased().trimmingCharacters(in: .whitespaces)

        if upper.hasSuffix("G") || upper.hasSuffix("GB") || upper.hasSuffix("GIB") {
            let numPart = upper.replacingOccurrences(of: "GIB", with: "")
                .replacingOccurrences(of: "GB", with: "")
                .replacingOccurrences(of: "G", with: "")
            guard let value = Int(numPart), value > 0 else { return nil }
            self.megabytes = value * 1024
        } else if upper.hasSuffix("M") || upper.hasSuffix("MB") || upper.hasSuffix("MIB") {
            let numPart = upper.replacingOccurrences(of: "MIB", with: "")
                .replacingOccurrences(of: "MB", with: "")
                .replacingOccurrences(of: "M", with: "")
            guard let value = Int(numPart), value > 0 else { return nil }
            self.megabytes = value
        } else if let value = Int(upper), value > 0 {
            self.megabytes = value
        } else {
            return nil
        }
    }

    var description: String {
        if megabytes >= 1024 && megabytes % 1024 == 0 {
            return "\(megabytes / 1024)G"
        }
        return "\(megabytes)M"
    }

    static var defaultValueDescription: String { "512M" }
}

struct MountSpec: Sendable {
    let source: String
    let destination: String

    init(source: String, destination: String) {
        self.source = source
        self.destination = destination
    }

    init(parsing raw: String) throws {
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw ContainerCastError.invalidMountFormat(mount: raw)
        }
        let src = NSString(string: parts[0]).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: src) else {
            throw ContainerCastError.mountPathNotFound(path: parts[0])
        }
        self.source = src
        self.destination = parts[1]
    }
}

enum Paths {
    /// Shared image store with the container CLI.
    static let containerStore = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!.appendingPathComponent("com.apple.container")
}
