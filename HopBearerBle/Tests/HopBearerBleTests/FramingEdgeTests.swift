// Additional deframer edge cases for the BLE wire format, beyond the pass-4 FramingTests set. These pin
// the streaming buffer's behavior at the awkward boundaries an L2CAP input stream actually produces:
// an empty read, a minimum (type-only) frame, a length prefix split across reads, a complete frame
// followed by a partial tail, and residue accounting. All pure BleDeframer math, no CBL2CAPChannel.

import XCTest
import Foundation
@testable import HopBearerBle

final class FramingEdgeTests: XCTestCase {

    func testEmptyFeedEmitsNothingAndBuffersNothing() {
        var d = BleDeframer()
        var over = false
        XCTAssertEqual(d.feed([], overLimit: &over), [])
        XCTAssertFalse(over)
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testMinimumFrameIsJustAOneByteType() {
        // len = 1 is the smallest valid frame (a bare type byte, e.g. a PONG-less control). It must decode.
        var d = BleDeframer()
        var over = false
        let out = d.feed(bleFrame([FRAME_PONG]), overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(out, [[FRAME_PONG]])
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testLengthPrefixSplitAcrossFeedsThenBody() {
        var d = BleDeframer()
        let body: [UInt8] = [FRAME_DATA, 0x01, 0x02, 0x03]
        let frame = bleFrame(body)
        var over = false
        // 2 of the 4 prefix bytes: not enough to even know the length yet.
        XCTAssertEqual(d.feed(Array(frame[0..<2]), overLimit: &over), [])
        XCTAssertEqual(d.bufferedCount, 2)
        // The other 2 prefix bytes: length now known, body still absent.
        XCTAssertEqual(d.feed(Array(frame[2..<4]), overLimit: &over), [])
        XCTAssertEqual(d.bufferedCount, 4)
        // The body arrives -> frame completes, buffer drains.
        XCTAssertEqual(d.feed(Array(frame[4...]), overLimit: &over), [body])
        XCTAssertFalse(over)
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testCompleteFrameThenPartialTailBuffersTheTail() {
        var d = BleDeframer()
        let a: [UInt8] = [FRAME_DATA, 0xAA]
        let b: [UInt8] = [FRAME_DATA, 0xBB, 0xCC, 0xDD]
        let feed = bleFrame(a) + Array(bleFrame(b).prefix(3))   // all of a + a partial b
        var over = false
        let out = d.feed(feed, overLimit: &over)
        XCTAssertEqual(out, [a], "only the complete frame is emitted")
        XCTAssertFalse(over)
        XCTAssertEqual(d.bufferedCount, 3, "the 3 partial bytes of b are retained for the next feed")
        // Deliver the rest of b -> it completes.
        let rest = Array(bleFrame(b).dropFirst(3))
        XCTAssertEqual(d.feed(rest, overLimit: &over), [b])
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testThreeBackToBackFramesInOneFeed() {
        var d = BleDeframer()
        let f1: [UInt8] = [FRAME_HELLO, 0x01]
        let f2: [UInt8] = [FRAME_PING, 0x02, 0x03]
        let f3: [UInt8] = [FRAME_DATA, 0x04]
        var over = false
        XCTAssertEqual(d.feed(bleFrame(f1) + bleFrame(f2) + bleFrame(f3), overLimit: &over), [f1, f2, f3])
        XCTAssertFalse(over)
    }

    func testResidueAfterEmittingKeepsOnlyThePartialBytes() {
        var d = BleDeframer()
        let whole: [UInt8] = [FRAME_DATA, 0x10, 0x20]
        var over = false
        // one whole frame + 1 stray byte of the next length prefix.
        _ = d.feed(bleFrame(whole) + [0x00], overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(d.bufferedCount, 1, "exactly the 1 leftover prefix byte is buffered")
    }
}
