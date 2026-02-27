import Foundation

/// Parsed directive from a Containerfile.
struct ContainerfileDirective: Sendable {
    let keyword: String
    let arguments: String
    let lineNumber: Int
}

/// Parses Containerfile directives for display purposes.
struct ContainerfileParser {
    static let knownDirectives: Set<String> = [
        "FROM", "RUN", "COPY", "ADD", "ENV", "EXPOSE", "ENTRYPOINT",
        "CMD", "WORKDIR", "USER", "LABEL", "VOLUME", "ARG", "SHELL",
        "HEALTHCHECK", "STOPSIGNAL", "ONBUILD",
    ]

    /// Parse a Containerfile into its directives.
    static func parse(contentsOf url: URL) throws -> [ContainerfileDirective] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content)
    }

    static func parse(_ content: String) -> [ContainerfileDirective] {
        var directives: [ContainerfileDirective] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }

            // Check for directive keyword
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard let first = parts.first else {
                i += 1
                continue
            }

            let keyword = String(first).uppercased()
            guard knownDirectives.contains(keyword) else {
                i += 1
                continue
            }

            // Collect continuation lines (ending with \)
            var fullLine = trimmed
            let lineNum = i + 1
            while fullLine.hasSuffix("\\") && i + 1 < lines.count {
                fullLine = String(fullLine.dropLast()).trimmingCharacters(in: .whitespaces)
                i += 1
                let next = lines[i].trimmingCharacters(in: .whitespaces)
                fullLine += " " + next
            }

            let args: String
            if let spaceIdx = fullLine.firstIndex(of: " ") {
                args = String(fullLine[fullLine.index(after: spaceIdx)...])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                args = ""
            }

            directives.append(ContainerfileDirective(
                keyword: keyword,
                arguments: args,
                lineNumber: lineNum
            ))
            i += 1
        }

        return directives
    }
}
