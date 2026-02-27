import Foundation

@main
struct Runner {
    static func main() async {
        do {
            let extractor = PayloadExtractor()
            let payload = try extractor.extract()
            let metadata = payload.metadata
            let env = ProcessInfo.processInfo.environment

            // All argv after the binary name goes to the guest process
            let guestArgs = Array(CommandLine.arguments.dropFirst())

            // Runtime overrides via environment variables
            let cpus = env["CAST_CPUS"].flatMap(Int.init) ?? metadata.cpus
            let memory = env["CAST_MEMORY"].flatMap { MemorySize(argument: $0)?.megabytes } ?? metadata.memory
            let noNetwork = env["CAST_NO_NETWORK"] != nil
            let timeout = env["CAST_TIMEOUT"].flatMap(Int.init) ?? 0

            // Parse mounts from CAST_MOUNT (semicolon-separated host:guest pairs)
            var mounts: [(source: String, destination: String)] = []
            if let mountStr = env["CAST_MOUNT"] {
                for raw in mountStr.split(separator: ";").map(String.init) {
                    let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else {
                        fputs("Invalid mount format '\(raw)'. Expected: /host/path:/container/path\n", stderr)
                        Darwin.exit(1)
                    }
                    let src = NSString(string: parts[0]).expandingTildeInPath
                    guard FileManager.default.fileExists(atPath: src) else {
                        fputs("Mount source '\(parts[0])' does not exist\n", stderr)
                        Darwin.exit(1)
                    }
                    mounts.append((source: src, destination: parts[1]))
                }
            }

            // TTY: respect baked preference but only if actual terminal is attached
            let wantsTTY = metadata.tty
                && isatty(STDIN_FILENO) != 0
                && isatty(STDOUT_FILENO) != 0
            let wantsInteractive = wantsTTY || metadata.interactive

            let options = VMBoot.Options(
                cpus: cpus,
                memory: memory,
                mounts: mounts,
                network: !noNetwork && metadata.network,
                interactive: wantsInteractive,
                tty: wantsTTY,
                timeout: timeout,
                command: guestArgs
            )

            let exitCode = try await VMBoot().boot(payload: payload, options: options)
            Darwin.exit(exitCode)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }
}

// Subset of container-cast/Types.swift MemorySize — keep in sync.
/// Parses human-readable memory sizes: 512M, 1G, 2048 (bare number = MB).
struct MemorySize {
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
}
