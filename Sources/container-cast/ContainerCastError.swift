import Foundation

enum ContainerCastError: LocalizedError {
    case containerfileNotFound(path: String)
    case buildFailed(reason: String)
    case kernelNotFound
    case initfsNotFound
    case runnerNotFound
    case mountPathNotFound(path: String)
    case invalidMountFormat(mount: String)
    case codesignFailed

    var errorDescription: String? {
        switch self {
        case .containerfileNotFound(let path):
            "Containerfile not found at '\(path)'"
        case .buildFailed(let reason):
            "Image build failed: \(reason)"
        case .kernelNotFound:
            "No kernel found. Run 'container setup' to install the container runtime."
        case .initfsNotFound:
            "No initfs image found. Run 'container setup' to install the container runtime."
        case .runnerNotFound:
            "container-cast-runner not found. Run 'make install' or 'make plugin'."
        case .mountPathNotFound(let path):
            "Mount source '\(path)' does not exist"
        case .invalidMountFormat(let mount):
            "Invalid mount format '\(mount)'. Expected: /host/path:/container/path"
        case .codesignFailed:
            "Failed to codesign the output binary."
        }
    }
}
