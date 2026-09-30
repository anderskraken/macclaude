import Darwin
import Foundation

enum BoundedFile {
    static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw posixError(url) }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError(url) }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ProfileStoreError.unsafeStorage("\(url.lastPathComponent) is not a regular file.")
        }
        guard status.st_size >= 0, status.st_size <= maximumBytes else {
            throw ProfileStoreError.unsafeStorage("\(url.lastPathComponent) is too large.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(16_384, maximumBytes + 1))
        while data.count <= maximumBytes {
            let remaining = min(buffer.count, maximumBytes + 1 - data.count)
            let count = Darwin.read(descriptor, &buffer, remaining)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(url)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw ProfileStoreError.unsafeStorage("\(url.lastPathComponent) is too large.")
    }

    private static func posixError(_ url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
    }
}
