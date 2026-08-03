import Foundation
import XCTest
@testable import HopBearerMeshtastic

/// Fragmentation + reassembly + dedup. The fragment-count vectors here MUST match
/// bearers/meshtastic-vectors.json (tools/meshtastic-parity.sh pins the same lengths on Android).
final class MeshFragmentTests: XCTestCase {

    func testFragmentCounts() {
        let cases: [(len: Int, frags: Int)] = [
            (0, 1), (1, 1), (200, 1), (201, 2), (400, 2), (401, 3), (1000, 5),
        ]
        for c in cases {
            let body = [UInt8](repeating: 0x5A, count: c.len)
            let frags = meshFragment(body, msgId: 1)
            XCTAssertNotNil(frags, "len \(c.len) should fragment")
            XCTAssertEqual(frags?.count, c.frags, "len \(c.len)")
            // Every fragment fits one packet (header + at most MESH_MAX_CHUNK).
            for f in frags ?? [] { XCTAssertLessThanOrEqual(f.count, MESH_FRAG_HEADER + MESH_MAX_CHUNK) }
        }
    }

    func testFragmentOversizeRefused() {
        let tooBig = [UInt8](repeating: 0, count: MESH_MAX_MESSAGE + 1)
        XCTAssertNil(meshFragment(tooBig, msgId: 1))
    }

    func testReassembleSingleFragment() {
        let rz = MeshReassembler()
        let body: [UInt8] = [M_DATA, 1, 2, 3]
        let frags = meshFragment(body, msgId: 7)!
        XCTAssertEqual(frags.count, 1)
        XCTAssertEqual(rz.accept(peer: 5, fragment: frags[0], nowS: 0), body)
    }

    func testReassembleMultiFragmentInOrder() {
        let rz = MeshReassembler()
        let body = [UInt8]((0..<500).map { UInt8($0 & 0xff) })
        let frags = meshFragment(body, msgId: 9)!
        XCTAssertEqual(frags.count, 3)
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[0], nowS: 0))
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[1], nowS: 0))
        XCTAssertEqual(rz.accept(peer: 1, fragment: frags[2], nowS: 0), body)
    }

    func testReassembleOutOfOrder() {
        let rz = MeshReassembler()
        let body = [UInt8]((0..<450).map { UInt8($0 & 0xff) })
        let frags = meshFragment(body, msgId: 3)!
        XCTAssertEqual(frags.count, 3)
        XCTAssertNil(rz.accept(peer: 2, fragment: frags[2], nowS: 0))
        XCTAssertNil(rz.accept(peer: 2, fragment: frags[0], nowS: 0))
        XCTAssertEqual(rz.accept(peer: 2, fragment: frags[1], nowS: 0), body)
    }

    func testDuplicateFragmentDoesNotDoubleComplete() {
        let rz = MeshReassembler()
        let body = [UInt8]((0..<300).map { UInt8($0 & 0xff) })
        let frags = meshFragment(body, msgId: 4)!   // 2 fragments
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[0], nowS: 0))
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[0], nowS: 0))   // dup of index 0
        XCTAssertEqual(rz.accept(peer: 1, fragment: frags[1], nowS: 0), body)
    }

    func testPeersDoNotCrossContaminate() {
        let rz = MeshReassembler()
        let body = [UInt8]((0..<250).map { UInt8($0 & 0xff) })
        let frags = meshFragment(body, msgId: 1)!   // 2 fragments
        XCTAssertNil(rz.accept(peer: 10, fragment: frags[0], nowS: 0))
        // Same msgId, different peer, only its first fragment: must not complete peer 10's message.
        XCTAssertNil(rz.accept(peer: 11, fragment: frags[0], nowS: 0))
        XCTAssertEqual(rz.accept(peer: 10, fragment: frags[1], nowS: 0), body)
    }

    func testStaleEviction() {
        let rz = MeshReassembler()
        let body = [UInt8]((0..<300).map { UInt8($0 & 0xff) })
        let frags = meshFragment(body, msgId: 1)!
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[0], nowS: 0))
        XCTAssertEqual(rz.partialPeerCount, 1)
        rz.evictStale(nowS: MESH_REASSEMBLY_TTL_S + 1)
        XCTAssertEqual(rz.partialPeerCount, 0)
        // The second fragment now arrives with no surviving partial -> cannot complete.
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[1], nowS: MESH_REASSEMBLY_TTL_S + 2))
    }

    func testForgetPeer() {
        let rz = MeshReassembler()
        let frags = meshFragment([UInt8](repeating: 1, count: 300), msgId: 1)!
        XCTAssertNil(rz.accept(peer: 1, fragment: frags[0], nowS: 0))
        rz.forget(peer: 1)
        XCTAssertEqual(rz.partialPeerCount, 0)
    }

    func testBadFragmentHeaderRejected() {
        let rz = MeshReassembler()
        XCTAssertNil(rz.accept(peer: 1, fragment: [1, 2], nowS: 0))          // runt (< 4 header bytes)
        XCTAssertNil(rz.accept(peer: 1, fragment: [0, 1, 3, 2], nowS: 0))    // index 3 >= count 2
        XCTAssertNil(rz.accept(peer: 1, fragment: [0, 1, 0, 0], nowS: 0))    // count 0
    }

    func testFragHeaderParse() {
        let h = MeshFragHeader([0x12, 0x34, 2, 5, 9, 9])
        XCTAssertEqual(h?.msgId, 0x1234)
        XCTAssertEqual(h?.index, 2)
        XCTAssertEqual(h?.count, 5)
        XCTAssertEqual(h?.chunk, [9, 9])
    }

    func testDedupKeepRule() {
        let big = Data([0xFF, 0x00, 0x00])
        let small = Data([0x01, 0x00, 0x00])
        XCTAssertTrue(meshKeepGreaterLeg(myId: big, peer: small))
        XCTAssertFalse(meshKeepGreaterLeg(myId: small, peer: big))
    }
}
