import Foundation

/// Decodes the bytes returned by Darwin's KERN_PROCARGS2 without inspecting or
/// returning the environment that follows argv in the same kernel buffer.
public enum ProcessArgumentBuffer {
    public static func decode(_ data: Data) -> [String]? {
        let headerSize = MemoryLayout<Int32>.size
        guard data.count > headerSize, data.count <= 8 * 1_024 * 1_024 else { return nil }
        return data.withUnsafeBytes { bytes in
            let argumentCount = bytes.loadUnaligned(as: Int32.self)
            guard argumentCount > 0, argumentCount < 65_536 else { return nil }

            // The native-endian argc is followed by an executable path, its NUL
            // terminator, optional NUL padding, then exactly argc C strings.
            var cursor = headerSize
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor > headerSize, cursor < bytes.count else { return nil }
            while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }

            var arguments: [String] = []
            for _ in 0..<argumentCount {
                let start = cursor
                while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
                guard cursor < bytes.count,
                      let argument = String(bytes: bytes[start..<cursor], encoding: .utf8) else { return nil }
                arguments.append(argument)
                // Skip precisely one terminator here. Additional NUL bytes are
                // empty arguments, not padding between arguments.
                cursor += 1
            }
            return arguments
        }
    }
}
