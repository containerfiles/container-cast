import ArgumentParser

import Foundation

struct InfoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Inspect a Containerfile and show what would be baked in."
    )

    @Argument(help: "Path to a Containerfile or directory containing one.")
    var path: String

    func run() throws {
        let inputURL = URL(fileURLWithPath: path).standardizedFileURL
        let containerfile: URL

        if FileManager.default.isDirectory(inputURL) {
            containerfile = inputURL.appendingPathComponent("Containerfile")
        } else {
            containerfile = inputURL
        }

        guard FileManager.default.fileExists(atPath: containerfile.path) else {
            throw ContainerCastError.containerfileNotFound(path: containerfile.path)
        }

        let directives = try ContainerfileParser.parse(contentsOf: containerfile)

        guard !directives.isEmpty else {
            print(styled("No directives found in \(containerfile.path)", .yellow))
            return
        }

        print()
        print("  \(styled("Containerfile", .bold, .white))  \(styled(containerfile.path, .dim))")
        print()

        // Group by keyword for summary
        let from = directives.filter { $0.keyword == "FROM" }
        let run = directives.filter { $0.keyword == "RUN" }
        let copy = directives.filter { $0.keyword == "COPY" || $0.keyword == "ADD" }
        let env = directives.filter { $0.keyword == "ENV" }
        let expose = directives.filter { $0.keyword == "EXPOSE" }
        let entrypoint = directives.first { $0.keyword == "ENTRYPOINT" }
        let cmd = directives.first { $0.keyword == "CMD" }
        let workdir = directives.last { $0.keyword == "WORKDIR" }
        let user = directives.last { $0.keyword == "USER" }
        let labels = directives.filter { $0.keyword == "LABEL" }
        let volumes = directives.filter { $0.keyword == "VOLUME" }
        let args = directives.filter { $0.keyword == "ARG" }

        // Base image
        for d in from {
            printField("FROM", d.arguments)
        }

        // Build
        if !args.isEmpty {
            for d in args {
                printField("ARG", d.arguments)
            }
        }

        if !run.isEmpty {
            printField("RUN", "\(run.count) instruction\(run.count == 1 ? "" : "s")")
            for d in run {
                print("       \(styled(truncate(d.arguments, to: 72), .dim))")
            }
        }

        if !copy.isEmpty {
            for d in copy {
                printField(d.keyword, d.arguments)
            }
        }

        // Runtime config
        if !env.isEmpty {
            for d in env {
                printField("ENV", d.arguments)
            }
        }

        if let workdir {
            printField("WORKDIR", workdir.arguments)
        }

        if let user {
            printField("USER", user.arguments)
        }

        if !expose.isEmpty {
            let ports = expose.map(\.arguments).joined(separator: ", ")
            printField("EXPOSE", ports)
        }

        if !volumes.isEmpty {
            for d in volumes {
                printField("VOLUME", d.arguments)
            }
        }

        if !labels.isEmpty {
            for d in labels {
                printField("LABEL", d.arguments)
            }
        }

        // Execution
        if let entrypoint {
            printField("ENTRYPOINT", entrypoint.arguments)
        }

        if let cmd {
            printField("CMD", cmd.arguments)
        }

        print()
    }

    private func printField(_ label: String, _ value: String) {
        let padded = label.padding(toLength: 11, withPad: " ", startingAt: 0)
        print("  \(styled(padded, .cyan)) \(value)")
    }

    private func truncate(_ s: String, to length: Int) -> String {
        if s.count <= length { return s }
        return String(s.prefix(length - 1)) + "\u{2026}"
    }
}
