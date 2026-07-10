// Wire-format tests for the BLE bearer (apple-07 coverage): the SPEC §4 length-prefix deframer, the
// frame/deframe round-trip, partial + back-to-back frame handling, and the oversized-length guard. These
// are the exact byte paths Link.deframe() runs, lifted into a pure value type so they need no
// CBL2CAPChannel (which cannot be constructed in a unit test).

import XCTest
import Foundation
@testable import HopBearerBle

final class FramingTests: XCTestCase {

    func testFrameAndDeframeRoundTrip() {
        var d = BleDeframer()
        let body: [UInt8] = [FRAME_DATA, 0xDE, 0xAD, 0xBE, 0xEF]
        var over = false
        let out = d.feed(bleFrame(body), overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(out, [body])
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testLengthPrefixIsBigEndian() {
        // Assert the exact wire bytes so a future endianness slip (silent cross-platform framing break)
        // fails here. A 5-byte body -> 00 00 00 05.
        XCTAssertEqual(Array(bleFrame([FRAME_HELLO, 1, 2, 3, 4]).prefix(4)), [0x00, 0x00, 0x00, 0x05])
    }

    func testBackToBackFramesInOneFeed() {
        var d = BleDeframer()
        let a: [UInt8] = [FRAME_PING, 0x01]
        let b: [UInt8] = [FRAME_DATA, 0x02, 0x03]
        var over = false
        XCTAssertEqual(d.feed(bleFrame(a) + bleFrame(b), overLimit: &over), [a, b])
        XCTAssertFalse(over)
    }

    func testPartialFrameIsBufferedThenCompleted() {
        var d = BleDeframer()
        let body: [UInt8] = [FRAME_DATA, 0xAA, 0xBB, 0xCC, 0xDD]
        let frame = bleFrame(body)
        var over = false
        XCTAssertEqual(d.feed(Array(frame.prefix(2)), overLimit: &over), [])   // length prefix incomplete
        XCTAssertEqual(d.feed(Array(frame[2..<5]), overLimit: &over), [])      // body incomplete
        XCTAssertEqual(d.feed(Array(frame[5...]), overLimit: &over), [body])   // completes
        XCTAssertFalse(over)
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testByteAtATimeStillReassembles() {
        var d = BleDeframer()
        let body: [UInt8] = [FRAME_DATA, 0x11, 0x22, 0x33]
        var emitted: [[UInt8]] = []
        var over = false
        for byte in bleFrame(body) { emitted += d.feed([byte], overLimit: &over) }
        XCTAssertFalse(over)
        XCTAssertEqual(emitted, [body])
    }

    func testOversizedLengthIsFlaggedOverLimit() {
        var d = BleDeframer()
        var over = false
        let out = d.feed([0x7F, 0xFF, 0xFF, 0xFF], overLimit: &over)   // ~2 GiB, past MAX_FRAME (4 MiB)
        XCTAssertTrue(over)
        XCTAssertEqual(out, [])
    }

    func testZeroLengthIsFlaggedOverLimit() {
        var d = BleDeframer()
        var over = false
        let out = d.feed([0x00, 0x00, 0x00, 0x00], overLimit: &over)   // len < 1 is invalid
        XCTAssertTrue(over)
        XCTAssertEqual(out, [])
    }

    func testValidFramesAheadOfBadLengthAreStillEmitted() {
        var d = BleDeframer()
        let good: [UInt8] = [FRAME_DATA, 0x42]
        var over = false
        let out = d.feed(bleFrame(good) + [0x7F, 0xFF, 0xFF, 0xFF], overLimit: &over)
        XCTAssertEqual(out, [good])
        XCTAssertTrue(over)
    }

    func testMaxSizedFrameIsAccepted() {
        var d = BleDeframer()
        let body = [UInt8](repeating: 0x5A, count: 4 * 1024 * 1024)   // exactly MAX_FRAME
        var over = false
        let out = d.feed(bleFrame(body), overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(out.first?.count, body.count)
    }
}
