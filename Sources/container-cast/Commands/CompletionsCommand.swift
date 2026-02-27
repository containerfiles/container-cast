import ArgumentParser

struct CompletionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "completions",
        abstract: "Generate zsh completion script.",
        shouldDisplay: false
    )

    func run() {
        var lines: [String] = []

        lines.append("#compdef container-cast")
        lines.append("")
        lines.append("_container_cast() {")
        lines.append("    local context state state_descr line")
        lines.append("    local -A opt_args")
        lines.append("")
        lines.append("    _arguments -C \\")
        lines.append("        '(-h --help)'{-h,--help}'[Show help]' \\")
        lines.append("        '--version[Show version]' \\")
        lines.append("        '1:command:->command' \\")
        lines.append("        '*::arg:->args'")
        lines.append("")
        lines.append("    case \"$state\" in")
        lines.append("    command)")

        lines.append("        local -a commands=(")
        for cmd in Help.commands {
            let escaped = cmd.description.replacingOccurrences(of: "'", with: "'\\''")
            lines.append("            '\(cmd.name):\(escaped)'")
        }
        lines.append("        )")
        lines.append("        _describe 'command' commands")
        lines.append("        ;;")

        lines.append("    args)")
        lines.append("        case \"$words[1]\" in")

        // cast
        lines.append("        cast)")
        lines.append("            _arguments \\")
        lines.append("                '(-o --output)'{-o,--output}'[Output binary path]:file:_files' \\")
        lines.append("                '--cpus[CPU cores]:cores:' \\")
        lines.append("                '--memory[Memory size]:memory:' \\")
        lines.append("                '--name[Binary name]:name:' \\")
        lines.append("                '--entrypoint[Override entrypoint]:cmd:' \\")
        lines.append("                '--no-network[Disable networking]' \\")
        lines.append("                '(-i --interactive)'{-i,--interactive}'[Bake interactive mode]' \\")
        lines.append("                '(-t --tty)'{-t,--tty}'[Bake TTY allocation]' \\")
        lines.append("                '--image[Use existing image]:image:' \\")
        lines.append("                ':path:_files'")
        lines.append("            ;;")

        // info
        lines.append("        info)")
        lines.append("            _arguments ':path:_files'")
        lines.append("            ;;")

        lines.append("        esac")
        lines.append("        ;;")
        lines.append("    esac")
        lines.append("}")
        lines.append("")
        lines.append("_container_cast \"$@\"")

        print(lines.joined(separator: "\n"))
    }
}
