import Foundation
import XCTest
import HopContract
@testable import HopBearerMeshtastic

/// Drives the full MeshtasticBearer state machine against a FakeRadio: connect handshake, discovery via
/// HELLO, reassembly of inbound DATA, outbound fragmentation, keepalive PING/PONG, and the dead-link reap.
/// No CoreBluetooth and no Meshtastic hardware; the whole state machine runs headlessly on the bearer's
/// serial queue.
final class MeshBearerTests: XCTestCase {
    // myId's first byte 0x80 is greater than a peer whose first byte is 0x01, so WE are the greater id.
    let myId = Data([0x80] + [UInt8](repeating: 0, count: 15))
    let peerId = Data([0x01] + [UInt8](repeating: 0, count: 15))
    let peerNode: UInt32 = 4242

    /// Build a bearer + fake radio, start it, and barrier so the async start setup completed.
    private func makeBearer() -> (MeshtasticBearer, FakeRadio, RecordingSink) {
        let radio = FakeRadio()
        let bearer = MeshtasticBearer(myId: myId, radio: radio)
        let sink = RecordingSink()
        bearer.sink = sink
        bearer.start()
        _ = bearer.testLinkCount   // meshQueue.sync barrier: start's async setup has run
        return (bearer, radio, sink)
    }

    /// Fire the radio connect + tell it our node num, then clear the ToRadio log so a test sees only what
    /// it triggers next. Returns after a queue barrier.
    private func connect(_ bearer: MeshtasticBearer, _ radio: FakeRadio, myNode: UInt32 = 7) {
        radio.fireConnect()
        radio.deliverMyNodeNum(myNode)
        _ = bearer.testLinkCount   // barrier
    }

    /// Deliver a full Hop link frame from `peerNode` by fragmenting it exactly as a peer bearer would.
    private func deliverFrame(_ bearer: MeshtasticBearer, _ radio: FakeRadio, _ frame: [UInt8]) {
        for frag in meshFragment(frame, msgId: 55)! {
            radio.deliverHopPacket(from: peerNode, payload: frag)
        }
        _ = bearer.testLinkCount   // barrier
    }

    private func bringLinkUp(_ bearer: MeshtasticBearer, _ radio: FakeRadio) {
        connect(bearer, radio)
        radio.clearSent()
        deliverFrame(bearer, radio, MeshFrame.hello(myId: peerId, isGreater: false))
    }

    func testStartStartsRadio() {
        let (_, radio, _) = makeBearer()
        XCTAssertTrue(radio.started)
    }

    func testConnectRequestsConfigAndBeaconsHello() {
        let (bearer, radio, _) = makeBearer()
        radio.fireConnect()
        _ = bearer.testLinkCount   // barrier

        // A want_config ToRadio (field 3) and a broadcast HELLO were sent.
        let wantConfig = radio.sent.contains { MeshTestDecode.toRadioFragment($0) == nil && !$0.isEmpty }
        XCTAssertTrue(wantConfig, "expected a want_config ToRadio")
        let helloBody = MeshTestDecode.frame(to: MESH_BROADCAST_ADDR, in: radio.sent)
        XCTAssertEqual(helloBody?.first, M_HELLO)
        XCTAssertEqual(MeshFrame.helloPeerId(helloBody ?? []), myId)
    }

    func testLearnsMyNodeNum() {
        let (bearer, radio, _) = makeBearer()
        radio.deliverMyNodeNum(99)
        XCTAssertEqual(bearer.testMyNodeNum, 99)
    }

    func testInboundHelloSurfacesLinkUpAsDialer() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)

        XCTAssertEqual(sink.ups.count, 1)
        XCTAssertEqual(sink.ups.first?.peer, peerId)
        // We are the greater id, so our Noise role is initiator (dialer).
        XCTAssertEqual(sink.ups.first?.dialer, true)
        XCTAssertEqual(bearer.testLinkCount, 1)

        // We answered with a unicast HELLO to the peer node carrying OUR nodeId and OUR greater-ness (1).
        let reply = MeshTestDecode.frame(to: peerNode, in: radio.sent)
        XCTAssertEqual(reply?.first, M_HELLO)
        XCTAssertEqual(MeshFrame.helloPeerId(reply ?? []), myId)
        XCTAssertEqual(reply?[17], 1)   // we are the greater id
    }

    func testDuplicateHelloDoesNotDoubleSurface() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)
        deliverFrame(bearer, radio, MeshFrame.hello(myId: peerId, isGreater: false))
        XCTAssertEqual(sink.ups.count, 1)   // still one link
        XCTAssertEqual(bearer.testLinkCount, 1)
    }

    func testInboundDataSurfacesBytes() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)
        let payload = [UInt8]((0..<350).map { UInt8($0 & 0xff) })   // multi-fragment
        deliverFrame(bearer, radio, MeshFrame.data(payload))
        XCTAssertEqual(sink.bytesEvents.count, 1)
        XCTAssertEqual(sink.bytesEvents.first.map { [UInt8]($0.data) }, payload)
    }

    func testDataBeforeLinkUpIsDropped() {
        let (bearer, radio, sink) = makeBearer()
        connect(bearer, radio)
        deliverFrame(bearer, radio, MeshFrame.data([1, 2, 3]))   // no HELLO yet
        XCTAssertTrue(sink.bytesEvents.isEmpty)
    }

    func testSendFragmentsToPeer() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)
        guard let link = sink.ups.first?.link else { return XCTFail("no link") }
        radio.clearSent()

        let payload = Data((0..<500).map { UInt8($0 & 0xff) })
        bearer.send(payload, on: link)
        _ = bearer.testLinkCount   // barrier

        // Every fragment addressed the peer node, and reassembled they are a DATA frame of our payload.
        XCTAssertTrue(MeshTestDecode.allFrames(radio.sent).allSatisfy { $0.to == peerNode })
        let body = MeshTestDecode.frame(to: peerNode, in: radio.sent)
        XCTAssertEqual(body?.first, M_DATA)
        XCTAssertEqual(body.map { Array($0.dropFirst()) }, [UInt8](payload))
    }

    func testPingElicitsPong() {
        let (bearer, radio, _) = makeBearer()
        bringLinkUp(bearer, radio)
        radio.clearSent()
        deliverFrame(bearer, radio, MeshFrame.ping(seq: 3, nowMs: 1000))
        let pong = MeshTestDecode.frame(to: peerNode, in: radio.sent)
        XCTAssertEqual(pong?.first, M_PONG)
    }

    func testMaintenanceReapsDeadLink() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)
        guard let link = sink.ups.first?.link else { return XCTFail("no link") }
        // Jump the clock past the dead deadline (lastRx was stamped with the real clock).
        bearer.testRunMaintenance(atMs: nowMs() + UInt64(MESH_DEAD_S * 1000) + 5000)
        XCTAssertEqual(sink.downs, [link])
        XCTAssertEqual(bearer.testLinkCount, 0)
    }

    func testMaintenancePingsLiveLink() {
        let (bearer, radio, _) = makeBearer()
        bringLinkUp(bearer, radio)
        radio.clearSent()
        bearer.testRunMaintenance(atMs: nowMs() + UInt64(MESH_PING_S * 1000) + 1000)
        // A keepalive PING went to the peer node.
        let frames = MeshTestDecode.allFrames(radio.sent)
        XCTAssertTrue(frames.contains { $0.to == peerNode && $0.body.first == M_PING })
    }

    func testStopTearsDownLinks() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)
        bearer.stop()
        _ = bearer.testLinkCount   // barrier
        XCTAssertTrue(radio.stopped)
        XCTAssertEqual(sink.downs.count, 1)
    }

    func testRadioDisconnectTearsDownLinks() {
        let (bearer, radio, sink) = makeBearer()
        bringLinkUp(bearer, radio)
        radio.fireDisconnect()
        _ = bearer.testLinkCount   // barrier
        XCTAssertEqual(sink.downs.count, 1)
        XCTAssertNil(bearer.testMyNodeNum)
    }

    func testSelfHelloEchoIgnored() {
        let (bearer, radio, sink) = makeBearer()
        connect(bearer, radio)
        // The mesh reflects our own broadcast HELLO back to us; it must not create a link.
        deliverFrame(bearer, radio, MeshFrame.hello(myId: myId, isGreater: false))
        XCTAssertEqual(bearer.testLinkCount, 0)
        XCTAssertTrue(sink.ups.isEmpty)
    }
}
