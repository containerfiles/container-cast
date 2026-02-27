import ArgumentParser

import Containerization
import ContainerizationEXT4
import ContainerizationOCI
import ContainerizationOS
import Foundation

struct CastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cast",
        abstract: "Cast a Containerfile into a self-contained macOS binary."
    )

    @Argument(help: "Path to a Containerfile or directory containing one.")
    var path: String

    @Option(name: .shortAndLong, help: "Output binary path.")
    var output: String?

    @Option(name: .long, help: "CPU cores baked into the binary.")
    var cpus: Int = 2

    @Option(name: .long, help: "Memory baked in (e.g. 512M, 1G).")
    var memory: MemorySize = MemorySize(argument: "512M")!

    @Option(name: .long, help: "Name shown in Activity Monitor.")
    var name: String?

    @Option(name: .long, help: "Override image entrypoint.")
    var entrypoint: String?

    @Flag(name: .long, help: "Boot without networking by default.")
    var noNetwork = false

    @Flag(name: .shortAndLong, help: "Bake interactive mode (keep stdin open).")
    var interactive = false

    @Flag(name: .shortAndLong, help: "Bake TTY allocation.")
    var tty = false

    @Option(name: .long, help: "Cast an existing image reference instead of building.")
    var image: String?

    func run() async throws {
        let fm = FileManager.default

        // Resolve Containerfile path
        let inputURL = URL(fileURLWithPath: path).standardizedFileURL
        let containerfile: URL
        let contextDir: URL

        if fm.isDirectory(inputURL) {
            containerfile = inputURL.appendingPathComponent("Containerfile")
            contextDir = inputURL
        } else {
            containerfile = inputURL
            contextDir = inputURL.deletingLastPathComponent()
        }

        guard image != nil || fm.fileExists(atPath: containerfile.path) else {
            throw ContainerCastError.containerfileNotFound(path: containerfile.path)
        }

        // Derive output name
        let outputName = name ?? contextDir.lastPathComponent
        let outputURL: URL
        if let output {
            outputURL = URL(fileURLWithPath: output).standardizedFileURL
        } else {
            outputURL = URL(fileURLWithPath: outputName)
        }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("cast-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        // 1. Build or reference the image
        let imageTag: String
        if let existingImage = image {
            imageTag = existingImage
            print(styled("Using image", .dim), styled(imageTag, .cyan))
        } else {
            let tag = "cast-\(UUID().uuidString.prefix(8).lowercased())"
            print(styled("Building image...", .dim))
            _ = try await ImageBuilder().build(containerfile: containerfile, context: contextDir, tag: tag)
            imageTag = tag
            print(styled("Image built", .dim), styled(tag, .cyan))
        }

        // 2. Open image store and find the image
        let storePath = Paths.containerStore
        let store = try ImageStore(path: storePath)

        let imageEntry = try await findImage(tag: imageTag, in: store)
        let config = try await imageEntry.config(for: .current)

        // Extract image config
        let imageConfig = config.config
        let imgEntrypoint = imageConfig?.entrypoint ?? []
        let imgCmd = imageConfig?.cmd ?? []
        let imgEnv = imageConfig?.env ?? []
        let imgWorkdir = imageConfig?.workingDir ?? "/"

        // 3. Unpack image to EXT4
        //    Size the filesystem to fit the content. The compressed layer sizes from
        //    the manifest are a lower bound — uncompressed content is typically 2-3x.
        //    We use 4x compressed size + 32 MB overhead for ext4 metadata as a safe estimate.
        print(styled("Unpacking to EXT4...", .dim))
        let rootfsPath = tempDir.appendingPathComponent("rootfs.ext4")
        let manifest = try await imageEntry.manifest(for: .current)
        let compressedSize = manifest.layers.reduce(UInt64(0)) { $0 + UInt64($1.size) }
        let estimatedSize = max(compressedSize * 4 + 32.mib(), 64.mib())
        let unpacker = EXT4Unpacker(blockSizeInBytes: estimatedSize)
        _ = try await unpacker.unpack(imageEntry, for: .current, at: rootfsPath)
        print(styled("Rootfs unpacked", .dim), formatFileSize(rootfsPath))

        // 4. Locate kernel from system store
        print(styled("Locating kernel...", .dim))
        let kernelPath = try findSystemKernel()
        print(styled("Kernel found", .dim))

        // 5. Locate initfs from system store
        print(styled("Locating initfs...", .dim))
        let initfsPath = try await findInitfs(store: store, tempDir: tempDir)
        print(styled("Initfs found", .dim))

        // 6. Locate the pre-built container-cast-runner binary
        let runnerPath = try findRunner()

        // 7. Build metadata
        let resolvedEntrypoint: [String]
        if let override = entrypoint {
            resolvedEntrypoint = override.split(separator: " ").map(String.init)
        } else {
            resolvedEntrypoint = imgEntrypoint
        }

        // Auto-detect interactive shells: if the effective command is a shell
        // and the user didn't explicitly set -i/-t, default to interactive+tty
        // since a shell with no stdin exits immediately.
        let effectiveCmd = resolvedEntrypoint.isEmpty ? imgCmd : resolvedEntrypoint
        let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/ash", "/bin/dash", "/bin/fish",
                                   "sh", "bash", "zsh", "ash", "dash", "fish"]
        let isShell = effectiveCmd.first.map { shells.contains($0) } ?? false
        let autoInteractive = isShell && !interactive && !tty

        let metadata = PayloadMetadata(
            name: outputName,
            entrypoint: resolvedEntrypoint,
            cmd: imgCmd,
            env: imgEnv,
            workdir: imgWorkdir,
            cpus: cpus,
            memory: memory.megabytes,
            network: !noNetwork,
            interactive: interactive || tty || autoInteractive,
            tty: tty || autoInteractive
        )

        // 8. Assemble the binary
        print(styled("Assembling binary...", .dim))
        let writer = PayloadWriter()
        try writer.write(
            input: PayloadWriter.Input(
                runnerBinary: runnerPath,
                kernel: kernelPath,
                initfs: initfsPath,
                rootfs: rootfsPath,
                metadata: metadata
            ),
            to: outputURL
        )

        // 9. Patch Mach-O: strip stale code signature, extend __LINKEDIT over payload
        try MachOPatcher.prepareForSigning(at: outputURL)

        // 10. Codesign with virtualization entitlement
        print(styled("Signing...", .dim))
        let entitlementsPlist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
            "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>com.apple.security.virtualization</key>
                <true/>
            </dict>
            </plist>
            """
        let entPath = tempDir.appendingPathComponent("cast.entitlements")
        try entitlementsPlist.write(to: entPath, atomically: true, encoding: .utf8)

        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = [
            "--force", "--sign", "-", "--timestamp=none",
            "--entitlements", entPath.path, outputURL.path,
        ]
        try codesign.run()
        codesign.waitUntilExit()
        guard codesign.terminationStatus == 0 else {
            throw ContainerCastError.codesignFailed
        }

        print()
        print("  \(styled("Cast", .bold, .green)) \(styled(outputURL.path, .white))")
        print("  \(styled("Run it:", .dim)) \(styled(outputURL.path, .cyan))")
        print()
    }

    // MARK: - Helpers

    /// Find an image in the store by tag prefix match (avoids OCI reference validation).
    private func findImage(tag: String, in store: ImageStore) async throws -> Containerization.Image {
        // Try exact reference first (works for fully-qualified refs like docker.io/library/alpine:latest)
        if let image = try? await store.get(reference: tag, pull: false) {
            return image
        }

        // Fall back to listing and matching by tag (for bare tags from container build)
        let allImages = try await store.list()
        if let match = allImages.first(where: { $0.reference.hasPrefix(tag) }) {
            return match
        }

        // Last resort: try with pull enabled (for remote references)
        return try await store.get(reference: tag, pull: true)
    }

    private func findSystemKernel() throws -> URL {
        let fm = FileManager.default
        let containerKernels = Paths.containerStore.appendingPathComponent("kernels")
        if fm.fileExists(atPath: containerKernels.path),
            let contents = try? fm.contentsOfDirectory(atPath: containerKernels.path)
        {
            for file in contents where file.hasPrefix("vmlinux") {
                return containerKernels.appendingPathComponent(file)
            }
        }
        throw ContainerCastError.kernelNotFound
    }

    private func findInitfs(store: ImageStore, tempDir: URL) async throws -> URL {
        let images = try await store.list()
        guard let vminit = images.first(where: { $0.reference.contains("vminit") }) else {
            throw ContainerCastError.initfsNotFound
        }

        // Unpack the initfs image to a temp EXT4 (inside tempDir so it's cleaned up with it)
        let initfsImage = try await store.get(reference: vminit.reference, pull: false)
        let initfsPath = tempDir.appendingPathComponent("initfs.ext4")
        let initManifest = try await initfsImage.manifest(for: .current)
        let initCompressedSize = initManifest.layers.reduce(UInt64(0)) { $0 + UInt64($1.size) }
        let initDiskSize = max(initCompressedSize * 4 + 32.mib(), 64.mib())
        let unpacker = EXT4Unpacker(blockSizeInBytes: initDiskSize)
        _ = try await unpacker.unpack(initfsImage, for: .current, at: initfsPath)
        return initfsPath
    }

    /// Find container-cast-runner: check sibling to this binary first, then system path.
    private func findRunner() throws -> URL {
        let fm = FileManager.default
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let siblingDir = executableURL.deletingLastPathComponent()

        // Sibling: same directory as this binary (plugin layout)
        let sibling = siblingDir.appendingPathComponent("container-cast-runner")
        if fm.fileExists(atPath: sibling.path) { return sibling }

        // System install path
        let system = URL(fileURLWithPath: "/usr/local/libexec/container-cast/container-cast-runner")
        if fm.fileExists(atPath: system.path) { return system }

        throw ContainerCastError.runnerNotFound
    }

    private func formatFileSize(_ url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? UInt64
        else { return "" }
        return styled("(\(formatBytes(size)))", .dim)
    }
}

// MARK: - FileManager helper

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}
