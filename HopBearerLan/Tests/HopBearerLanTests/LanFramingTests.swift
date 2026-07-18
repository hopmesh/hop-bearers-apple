// Wire-format tests for the LAN bearer (apple-07 coverage): the length-prefix deframer, the
// frame/deframe round-trip, partial + back-to-back frame handling, the oversized-length guard, and the
// Bonjour-name hex parse. These are the exact byte paths LanLink.deframe() runs, lifted into pure value
// types so they need no socket.

import XCTest
import Foundation
@testable import HopBearerLan

final class LanFramingTests: XCTestCase {

    // MARK: lanFrame / LanDeframer round-trip.

    func testFrameAndDeframeRoundTrip() {
        var d = LanDeframer()
        let body: [UInt8] = [L_DATA, 0xDE, 0xAD, 0xBE, 0xEF]
        var over = false
        let out = d.feed(lanFrame(body), overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first, body)
        XCTAssertEqual(d.bufferedCount, 0, "a fully consumed frame leaves no residue")
    }

    func testLengthPrefixIsBigEndian() {
        // A 5-byte body -> prefix 00 00 00 05. Assert the exact wire bytes so a future endianness slip
        // (which would silently break cross-platform framing) fails here.
        let frame = lanFrame([L_HELLO, 1, 2, 3, 4])
        XCTAssertEqual(Array(frame.prefix(4)), [0x00, 0x00, 0x00, 0x05])
    }

    func testBackToBackFramesInOneFeed() {
        var d = LanDeframer()
        let a: [UInt8] = [L_PING, 0x01]
        let b: [UInt8] = [L_DATA, 0x02, 0x03]
        var over = false
        let out = d.feed(lanFrame(a) + lanFrame(b), overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(out, [a, b], "two frames in one feed come out in arrival order")
    }

    func testPartialFrameIsBufferedThenCompleted() {
        var d = LanDeframer()
        let body: [UInt8] = [L_DATA, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]
        let frame = lanFrame(body)
        var over = false
        // Feed only the first 3 bytes: not even the 4-byte length prefix is complete yet.
        XCTAssertEqual(d.feed(Array(frame.prefix(3)), overLimit: &over), [])
        XCTAssertFalse(over)
        // Feed the middle: length prefix now known but the body is incomplete -> still nothing emitted.
        XCTAssertEqual(d.feed(Array(frame[3..<6]), overLimit: &over), [])
        XCTAssertFalse(over)
        // Feed the rest: the frame completes and is emitted whole.
        let out = d.feed(Array(frame[6...]), overLimit: &over)
        XCTAssertEqual(out, [body])
        XCTAssertEqual(d.bufferedCount, 0)
    }

    func testByteAtATimeStillReassembles() {
        var d = LanDeframer()
        let body: [UInt8] = [L_DATA, 0x11, 0x22, 0x33]
        let frame = lanFrame(body)
        var emitted: [[UInt8]] = []
        var over = false
        for byte in frame { emitted += d.feed([byte], overLimit: &over) }
        XCTAssertFalse(over)
        XCTAssertEqual(emitted, [body], "a frame delivered one byte at a time still reassembles")
    }

    func testOversizedLengthIsFlaggedOverLimit() {
        var d = LanDeframer()
        // A length prefix well past the protocol's 1 MiB LAN_MAX_FRAME. 0x7FFFFFFF is ~2 GiB.
        var over = false
        let out = d.feed([0x7F, 0xFF, 0xFF, 0xFF], overLimit: &over)
        XCTAssertTrue(over, "a length beyond LAN_MAX_FRAME must flag overLimit so the link closes")
        XCTAssertEqual(out, [])
    }

    func testZeroLengthIsFlaggedOverLimit() {
        var d = LanDeframer()
        // len < 1 is invalid (every frame carries at least a 1-byte type). It must flag, not loop.
        var over = false
        let out = d.feed([0x00, 0x00, 0x00, 0x00], overLimit: &over)
        XCTAssertTrue(over)
        XCTAssertEqual(out, [])
    }

    func testValidFramesAheadOfBadLengthAreStillEmitted() {
        var d = LanDeframer()
        let good: [UInt8] = [L_DATA, 0x42]
        var over = false
        // A good frame followed by an oversized-length prefix: the good frame is emitted, THEN overLimit.
        let out = d.feed(lanFrame(good) + [0x7F, 0xFF, 0xFF, 0xFF], overLimit: &over)
        XCTAssertEqual(out, [good], "a frame ahead of the bad length is still delivered")
        XCTAssertTrue(over)
    }

    func testMaxSizedFrameIsAccepted() {
        var d = LanDeframer()
        // Exactly LAN_MAX_FRAME bytes of body must be accepted (boundary, not over).
        XCTAssertEqual(LAN_MAX_FRAME, 1 << 20)
        let body = [UInt8](repeating: 0x5A, count: LAN_MAX_FRAME)
        var over = false
        let out = d.feed(lanFrame(body), overLimit: &over)
        XCTAssertFalse(over)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.count, body.count)
    }

    func testIncrementalBufferBudgetRejectsBeforeAppendGrowth() {
        var d = LanDeframer()
        var over = false
        let prefix = Array(lanFrame([UInt8](repeating: 0, count: LAN_MAX_FRAME)).prefix(4))
        XCTAssertEqual(d.feed(prefix, overLimit: &over), [])
        XCTAssertFalse(over)
        XCTAssertEqual(d.feed([UInt8](repeating: 0x41, count: LAN_MAX_FRAME - 1), overLimit: &over), [])
        XCTAssertFalse(over)
        let retained = d.bufferedCount
        XCTAssertEqual(d.feed([0x42, 0x43], overLimit: &over), [])
        XCTAssertTrue(over)
        XCTAssertEqual(d.bufferedCount, retained, "rejected bytes never enter the deframer")
    }

    func testGlobalAdmissionCapsLinksAndAggregateBytes() {
        let admission = LanAdmission(maxLinks: 3, maxBytesPerLink: 10, maxBytesTotal: 15)
        let a = admission.tryAcquire()!
        let b = admission.tryAcquire()!
        let c = admission.tryAcquire()!
        XCTAssertNil(admission.tryAcquire(), "cap+1 link is rejected")
        XCTAssertTrue(a.reserve(10))
        XCTAssertTrue(b.reserve(5))
        XCTAssertFalse(c.reserve(1), "aggregate exhaustion rejects before allocation")
        XCTAssertFalse(b.reserve(6), "per-link growth is bounded")
        XCTAssertEqual(admission.retainedBytes, 15)

        a.close(); a.close()
        XCTAssertEqual(admission.retainedBytes, 5, "cleanup is idempotent")
        XCTAssertTrue(c.reserve(10))
        b.release(5); b.close(); c.close()
        XCTAssertEqual(admission.linkCount, 0)
        XCTAssertEqual(admission.retainedBytes, 0)
    }

    func testConcurrentSlowPeersStopExactlyAtGlobalCap() {
        let admission = LanAdmission(maxLinks: LAN_MAX_PENDING_LINKS,
                                     maxBytesPerLink: 1,
                                     maxBytesTotal: LAN_MAX_PENDING_LINKS)
        let lock = NSLock()
        var leases: [LanAdmission.Lease] = []
        let group = DispatchGroup()
        for _ in 0..<(LAN_MAX_PENDING_LINKS * 2) {
            group.enter()
            DispatchQueue.global().async {
                if let lease = admission.tryAcquire() {
                    lock.lock(); leases.append(lease); lock.unlock()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(leases.count, LAN_MAX_PENDING_LINKS)
        XCTAssertEqual(admission.linkCount, LAN_MAX_PENDING_LINKS)
        leases.forEach { $0.close() }
        XCTAssertEqual(admission.linkCount, 0)
    }

    // MARK: Bonjour instance-name <-> nodeId hex parse (peerIdFromName).

    func testPeerIdFromNameParsesValid32HexChars() {
        let id = Data((0..<16).map { UInt8($0) })                 // 00 01 02 ... 0f
        let name = id.map { String(format: "%02x", $0) }.joined() // 32 hex chars
        XCTAssertEqual(peerIdFromName(name), id)
    }

    func testPeerIdFromNameRejectsWrongLength() {
        XCTAssertNil(peerIdFromName(""))
        XCTAssertNil(peerIdFromName("abcd"))                       // too short
        XCTAssertNil(peerIdFromName(String(repeating: "a", count: 34)))   // too long
    }

    func testPeerIdFromNameRejectsNonHex() {
        // 32 chars but not all valid hex -> nil (a malformed advert must not yield a bogus 16-byte id).
        XCTAssertNil(peerIdFromName(String(repeating: "zz", count: 16)))
    }

    func testPeerIdFromNameUppercaseHexRoundTrips() {
        // UInt8(_, radix: 16) accepts uppercase; a peer that upper-cased its advert still parses.
        let name = "AABBCCDDEEFF00112233445566778899"
        let parsed = peerIdFromName(name)
        XCTAssertEqual(parsed?.count, 16)
        XCTAssertEqual(parsed?.first, 0xAA)
        XCTAssertEqual(parsed?.last, 0x99)
    }
}
