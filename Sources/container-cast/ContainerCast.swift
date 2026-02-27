import ArgumentParser


@main
struct ContainerCast: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: nil,
        abstract: "Cast Containerfiles into self-contained macOS binaries.",
        version: "container-cast 1.0.0",
        subcommands: [
            CastCommand.self,
            InfoCommand.self,
            CompletionsCommand.self,
        ],
        defaultSubcommand: CastCommand.self
    )

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let subcommands: Set<String> = ["cast", "info", "completions"]
        let isTopLevel = !args.contains(where: { subcommands.contains($0) })
        let wantsHelp = args.contains("-h") || args.contains("--help")
            || args.first == "help" && args.count <= 1
        let wantsVersion = args.contains("--version")

        if isTopLevel && wantsHelp {
            Help.print()
            return
        }

        if wantsVersion {
            Swift.print(configuration.version)
            return
        }

        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }
}
