

enum Help {
    struct Entry {
        let name: String
        let args: String
        let description: String
        let tag: String?

        var labelWidth: Int {
            args.isEmpty ? name.count : name.count + 1 + args.count
        }
    }

    // MARK: - Command Groups

    static let commands: [Entry] = [
        Entry(name: "cast", args: "<path> [options]", description: "Cast a Containerfile into a binary", tag: "default"),
        Entry(name: "info", args: "<path>", description: "Inspect a Containerfile", tag: nil),
    ]

    static let options: [Entry] = [
        Entry(name: "-h, --help", args: "", description: "Show help information", tag: nil),
        Entry(name: "--version", args: "", description: "Show the version", tag: nil),
    ]

    // MARK: - Render

    static func print() {
        let all = commands + options
        let labelWidth = all.map(\.labelWidth).max()! + 3

        Swift.print()
        Swift.print("  \(styled("container-cast", .bold, .white))  \(styled("Cast Containerfiles into self-contained macOS binaries.", .dim))")
        Swift.print()
        Swift.print("  \(styled("Usage", .bold))  \(styled("container-cast", .white)) \(styled("<command>", .cyan)) \(styled("[options]", .dim))")
        Swift.print()
        printSection("Commands", commands, labelWidth: labelWidth)
        printSection("Options", options, labelWidth: labelWidth)
    }

    private static func styledLabel(_ entry: Entry, paddedTo width: Int) -> String {
        if entry.args.isEmpty {
            return styled(entry.name, .cyan).padded(to: width)
        }
        return (styled(entry.name, .cyan) + " " + styled(entry.args, .dim)).padded(to: width)
    }

    private static func printSection(_ title: String, _ entries: [Entry], labelWidth: Int) {
        Swift.print("  \(styled(title, .bold))")
        Swift.print()
        for entry in entries {
            let label = styledLabel(entry, paddedTo: labelWidth)
            let desc = styled(entry.description, .white)
            let tag = entry.tag.map { " " + styled("(\($0))", .dim) } ?? ""
            Swift.print("    \(label)\(desc)\(tag)")
        }
        Swift.print()
    }
}
