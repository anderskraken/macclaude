import Foundation
import XCTest
@testable import MacClaudeCore

final class ProcessArgumentBufferTests: XCTestCase {
    func testDecodesPaddedExecutablePathAndBothArgumentForms() {
        let arguments = ["/Applications/Claude.app/Contents/MacOS/Claude", "--user-data-dir", "/Users/example/Account With Spaces", "--other=value"]
        for padding in [0, 1, 3, 64] {
            let data = buffer(arguments: arguments.map { Array($0.utf8) }, padding: padding)
            XCTAssertEqual(ProcessArgumentBuffer.decode(data), arguments)
        }
    }

    func testEmptyInteriorAndFinalArgumentsArePreserved() {
        let arguments = ["Claude", "", "--user-data-dir", "", ""]
        XCTAssertEqual(ProcessArgumentBuffer.decode(buffer(arguments: arguments.map { Array($0.utf8) })), arguments)
        let decoded = ProcessArgumentBuffer.decode(buffer(arguments: [Array("Claude".utf8), Array("--user-data-dir".utf8), []]))
        XCTAssertEqual(InstanceProfile.classify(arguments: decoded), .unknown)
    }

    func testEnvironmentIsNeverReturnedOrDecoded() {
        let arguments = ["Claude", "--user-data-dir=/tmp/example"]
        let data = buffer(arguments: arguments.map { Array($0.utf8) }, environment: [
            Array("SYNTHETIC_SECRET=never_return_this".utf8), [0xff, 0xfe]
        ])
        XCTAssertEqual(ProcessArgumentBuffer.decode(data), arguments)
    }

    func testInvalidUTF8InAnyArgumentFailsClosed() {
        XCTAssertNil(ProcessArgumentBuffer.decode(buffer(arguments: [[0xff]])))
        XCTAssertNil(ProcessArgumentBuffer.decode(buffer(arguments: [Array("Claude".utf8), [0xc3, 0x28]])))
    }

    func testRejectsZeroNegativeAndExcessiveArgumentCounts() {
        for count: Int32 in [0, -1, 65_536, Int32.max] {
            XCTAssertNil(ProcessArgumentBuffer.decode(buffer(arguments: [Array("Claude".utf8)], argumentCount: count)))
        }
    }

    func testRejectsTruncatedHeaderExecutableAndArguments() {
        for length in 0...MemoryLayout<Int32>.size {
            XCTAssertNil(ProcessArgumentBuffer.decode(Data(repeating: 0, count: length)))
        }
        var noExecutableTerminator = header(argumentCount: 1)
        noExecutableTerminator.append(contentsOf: Array("/Applications/Claude".utf8))
        XCTAssertNil(ProcessArgumentBuffer.decode(noExecutableTerminator))

        var noExecutable = header(argumentCount: 1)
        noExecutable.append(contentsOf: [0, 0, 0])
        noExecutable.append(contentsOf: Array("Claude\0".utf8))
        XCTAssertNil(ProcessArgumentBuffer.decode(noExecutable))

        var noArguments = header(argumentCount: 1)
        noArguments.append(contentsOf: Array("/Applications/Claude\0\0\0".utf8))
        XCTAssertNil(ProcessArgumentBuffer.decode(noArguments))

        var unterminatedArgument = buffer(arguments: [Array("Claude".utf8)])
        unterminatedArgument.removeLast()
        XCTAssertNil(ProcessArgumentBuffer.decode(unterminatedArgument))
        XCTAssertNil(ProcessArgumentBuffer.decode(buffer(arguments: [Array("Claude".utf8)], argumentCount: 2)))
    }

    func testSlicedDataAndUnicodeArgumentsDecodeWithoutIndexAssumptions() {
        let arguments = ["Claude", "--user-data-dir=/Users/Økonomi/研究"]
        var prefixed = Data([1, 2, 3])
        prefixed.append(buffer(arguments: arguments.map { Array($0.utf8) }))
        XCTAssertEqual(ProcessArgumentBuffer.decode(prefixed.dropFirst(3)), arguments)
    }

    func testRejectsOversizedKernelBuffer() {
        XCTAssertNil(ProcessArgumentBuffer.decode(Data(repeating: 0, count: 8 * 1_024 * 1_024 + 1)))
    }

    private func header(argumentCount: Int32) -> Data {
        var count = argumentCount
        return withUnsafeBytes(of: &count) { Data($0) }
    }

    private func buffer(arguments: [[UInt8]], argumentCount: Int32? = nil, padding: Int = 3, environment: [[UInt8]] = []) -> Data {
        var data = header(argumentCount: argumentCount ?? Int32(arguments.count))
        data.append(contentsOf: Array("/Applications/Claude.app/Contents/MacOS/Claude".utf8))
        data.append(contentsOf: [UInt8](repeating: 0, count: padding + 1))
        for argument in arguments {
            data.append(contentsOf: argument)
            data.append(0)
        }
        for entry in environment {
            data.append(contentsOf: entry)
            data.append(0)
        }
        return data
    }
}
