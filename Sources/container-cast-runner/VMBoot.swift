import Containerization
import ContainerizationOS
import Foundation
import os

/// Boots a VM from extracted payload files.
struct VMBoot {
    private let log = Logger(subsystem: "com.containerfiles.container-cast", category: "vm-boot")

    struct Options: Sendable {
        var cpus: Int
        var memory: Int
        var mounts: [(source: String, destination: String)]
        var network: Bool
        var interactive: Bool
        var tty: Bool
        var timeout: Int
        var command: [String]
    }

    func boot(payload: PayloadExtractor.ExtractedPayload, options: Options) async throws -> Int32 {
        let metadata = payload.metadata
        log.info("Booting VM '\(metadata.name, privacy: .public)'")

        // Kernel
        let kernel = Kernel(path: payload.kernelPath, platform: .linuxArm)

        // Initfs mount
        let initfsMount = Mount.block(
            format: "ext4",
            source: payload.initfsPath.path,
            destination: "/",
            options: ["ro"]
        )

        // Rootfs mount
        let rootfsMount = Mount.block(
            format: "ext4",
            source: payload.rootfsPath.path,
            destination: "/"
        )

        // VMM
        let vmm = VZVirtualMachineManager(
            kernel: kernel,
            initialFilesystem: initfsMount
        )

        // Networking
        var networkManager: ContainerManager.VmnetNetwork?
        var iface: (any Interface)?
        let containerID = "cast-\(UUID().uuidString.prefix(8))"

        if options.network {
            var net = try ContainerManager.VmnetNetwork()
            iface = try net.create(containerID)
            networkManager = net
        }

        // TTY setup
        let terminal: Terminal?
        if options.tty {
            let current = try Terminal.current
            try current.setraw()
            terminal = current
        } else {
            terminal = nil
        }
        defer { terminal?.tryReset() }

        // Resolve command: CLI override > metadata entrypoint + cmd
        let args: [String]
        if !options.command.isEmpty {
            args = options.command
        } else if !metadata.entrypoint.isEmpty {
            args = metadata.entrypoint + metadata.cmd
        } else {
            args = metadata.cmd
        }

        log.info("Container: \(containerID, privacy: .public), cmd: \(args, privacy: .public)")

        // Build configuration
        var config = LinuxContainer.Configuration()
        config.cpus = options.cpus
        config.memoryInBytes = UInt64(options.memory).mib()
        config.process.arguments = args
        config.process.workingDirectory = metadata.workdir
        config.process.environmentVariables = metadata.env

        if let terminal {
            config.process.setTerminalIO(terminal: terminal)
        } else {
            if options.interactive {
                config.process.stdin = FileHandleReaderStream.stdin
            }
            config.process.stdout = FileHandleWriter.stdout
            config.process.stderr = FileHandleWriter.stderr
        }

        if let iface {
            config.interfaces = [iface]
            config.dns = DNS()
            fputs("Network: \(iface.ipv4Address.address)\n", stderr)
        }

        // Host mounts
        for mount in options.mounts {
            config.mounts.append(
                .share(source: mount.source, destination: mount.destination)
            )
        }

        let container = try LinuxContainer(
            containerID,
            rootfs: rootfsMount,
            vmm: vmm,
            configuration: config
        )

        let sigwinchHandler = AsyncSignalHandler.create(notify: [SIGWINCH])

        defer {
            if var net = networkManager {
                try? net.release(containerID)
            }
        }

        try await container.create()
        try await container.start()

        if let terminal {
            try? await container.resize(to: try terminal.size)
        }

        let exitStatus: ExitStatus

        if options.timeout > 0 {
            exitStatus = try await withThrowingTaskGroup(of: ExitStatus.self) { group in
                group.addTask {
                    for await _ in sigwinchHandler.signals {
                        if let terminal {
                            try? await container.resize(to: try terminal.size)
                        }
                    }
                    throw CancellationError()
                }

                group.addTask {
                    try await container.wait()
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(options.timeout))
                    throw RunnerError.timeout(seconds: options.timeout)
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        } else {
            exitStatus = try await withThrowingTaskGroup(of: ExitStatus.self) { group in
                group.addTask {
                    for await _ in sigwinchHandler.signals {
                        if let terminal {
                            try? await container.resize(to: try terminal.size)
                        }
                    }
                    throw CancellationError()
                }

                group.addTask {
                    try await container.wait()
                }

                let result = try await group.next()!
                group.cancelAll()
                return result
            }
        }

        try await container.stop()
        log.info("VM exited with code \(exitStatus.exitCode)")
        return exitStatus.exitCode
    }
}

enum RunnerError: LocalizedError {
    case timeout(seconds: Int)

    var errorDescription: String? {
        switch self {
        case .timeout(let s): "VM killed after \(s)s timeout"
        }
    }
}
