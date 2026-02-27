import Containerization
import Foundation

/// Writer that forwards data to a FileHandle (stdout or stderr).
final class FileHandleWriter: Writer, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        handle.write(data)
    }

    func close() throws {}

    static let stdout = FileHandleWriter(.standardOutput)
    static let stderr = FileHandleWriter(.standardError)
}

/// ReaderStream that reads from a FileHandle (stdin).
final class FileHandleReaderStream: ReaderStream, @unchecked Sendable {
    private let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func stream() -> AsyncStream<Data> {
        let handle = self.handle
        return AsyncStream { continuation in
            Task.detached {
                while true {
                    let data = handle.availableData
                    if data.isEmpty {
                        continuation.finish()
                        break
                    }
                    continuation.yield(data)
                }
            }
        }
    }

    static let stdin = FileHandleReaderStream(.standardInput)
}
