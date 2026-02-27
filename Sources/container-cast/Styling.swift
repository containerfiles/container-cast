import Foundation

let isTerminal: Bool = isatty(STDOUT_FILENO) != 0
    || ProcessInfo.processInfo.environment["FORCE_COLOR"] != nil

enum Color: Sendable {
    case reset, bold, dim
    case red, green, yellow, cyan, white

    var rawValue: String {
        switch self {
        case .reset:  return "\u{001B}[0m"
        case .bold:   return "\u{001B}[1m"
        case .dim:    return "\u{001B}[2m"
        case .red:    return "\u{001B}[38;2;224;108;117m"
        case .green:  return "\u{001B}[38;2;152;195;121m"
        case .yellow: return "\u{001B}[38;2;229;192;123m"
        case .cyan:   return "\u{001B}[38;2;86;182;194m"
        case .white:  return "\u{001B}[38;2;171;178;191m"
        }
    }
}

func styled(_ text: String, _ colors: Color...) -> String {
    guard isTerminal else { return text }
    let codes = colors.map { $0.rawValue }.joined()
    return "\(codes)\(text)\(Color.reset.rawValue)"
}

extension String {
    var strippingANSI: String {
        replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }

    func padded(to width: Int) -> String {
        let visible = self.strippingANSI.count
        if visible >= width { return self }
        return self + String(repeating: " ", count: width - visible)
    }
}
