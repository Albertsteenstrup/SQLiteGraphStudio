import Foundation
import XCTest
@testable import StudioMCP

final class MCPLineFramerTests: XCTestCase {
    func testBuffersPartialMessagesAndSeparatesLines() throws {
        var framer = MCPLineFramer()
        XCTAssertEqual(try framer.append(Data("{\"a\":1}".utf8)), [])
        XCTAssertTrue(framer.hasPartialMessage)

        let messages = try framer.append(Data("\n{\"b\":2}\r\n".utf8))
        XCTAssertEqual(messages, [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])
        XCTAssertFalse(framer.hasPartialMessage)
    }

    func testRejectsOversizedLineAndResetsBufferedBytes() {
        var framer = MCPLineFramer(maximumMessageBytes: 4)
        XCTAssertThrowsError(try framer.append(Data("12345".utf8))) { error in
            XCTAssertEqual(error as? MCPLineFramingError, .messageTooLarge)
        }
        XCTAssertFalse(framer.hasPartialMessage)
    }

    func testRejectsOversizedCompletedMessage() {
        var framer = MCPLineFramer(maximumMessageBytes: 4)
        XCTAssertThrowsError(try framer.append(Data("12345\n".utf8))) { error in
            XCTAssertEqual(error as? MCPLineFramingError, .messageTooLarge)
        }
    }
}
