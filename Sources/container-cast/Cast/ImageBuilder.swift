import Foundation
import os

/// Builds a container image from a Containerfile using the `container` CLI.
struct ImageBuilder {
    private let log = Logger(subsystem: "com.containerfiles.container-cast", category: "image-builder")

    struct BuildResult {
        let tag: String
    }

    /// Build an image from a Containerfile.
    func build(containerfile: URL, context: URL, tag: String) async throws -> BuildResult {
        log.info("Building image \(tag, privacy: .public) from \(containerfile.path, privacy: .public)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/local/bin/container-build")
        process.arguments = [
            "--no-cache",
            "--tag", tag,
            "--file", containerfile.path,
            context.path,
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw ContainerCastError.buildFailed(reason: errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        log.info("Image \(tag, privacy: .public) built successfully")
        return BuildResult(tag: tag)
    }
}
