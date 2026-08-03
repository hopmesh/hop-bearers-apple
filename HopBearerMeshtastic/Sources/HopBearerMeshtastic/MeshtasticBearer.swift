// MeshtasticBearer, the Hop transport that RELAYS through a connected Meshtastic radio. A phone pairs
// with a nearby Meshtastic device (over BLE); that device is a gateway into a LoRa mesh where every other
// radio relays packets hop by hop. This bearer turns that mesh into a Hop transport: each remote Meshtastic
// node that is also running Hop becomes a peer, Hop link frames are fragmented into LoRa-sized Meshtastic
// packets on a private app port, and the mesh carries them. The result the consumer sees is identical to
// any other bearer: linkUp / linkBytes / linkDown keyed on the peer's 16-byte nodeId.
//
// TESTABILITY. All Meshtastic PROTOCOL logic (protobuf, fragmentation, the Hop link-frame grammar, dedup)
// lives in MeshtasticWire.swift and is unit-tested with no radio. This file owns the LINK STATE MACHINE
// and drives a `MeshtasticRadio` seam that moves raw ToRadio/FromRadio protobuf frames over the wire. In
// production the seam is CoreBluetoothMeshtasticRadio (MeshtasticBearer+Radio.swift, the CoreBluetooth GATT
// client, excluded from the coverage denominator like every bearer's radio glue). In tests it is a fake
// radio, so the whole state machine (connect, discover, reassemble, dedup, keepalive, reap, send) runs
// headlessly on a serial queue with an injected clock.
//
// THREADING. One serial queue (`meshQueue`) owns every link/reassembly/timer mutation, so the bearer is
// single-threaded end to end and needs no locks (the same discipline the LAN bearer gets from `lanQueue`).
// The radio delivers inbound frames onto this queue.

import Foundation
import HopContract

/// The seam between the link state machine and the physical Meshtastic device. It moves opaque protobuf
/// frames: `send(toRadio:)` writes one `ToRadio`, and `onFromRadio` fires once per decoded `FromRadio`.
/// Connection lifecycle is reported via `onConnect` / `onDisconnect`. Callbacks are delivered on the
/// bearer's `meshQueue`.
protocol MeshtasticRadio: AnyObject {
    var onConnect: (() -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    var onFromRadio: (([UInt8]) -> Void)? { get set }
    func start()
    func stop()
    func send(toRadio bytes: [UInt8])
}

/// One logical link to a remote Meshtastic node. There is at most one per (peer node num), created when
/// the first HELLO from that node is reassembled.
final class MeshLink {
    let linkId: LinkId
    let nodeNum: UInt32
    var peerId: Data
    /// True iff MY nodeId is the greater one (the Noise initiator, mirroring "greater dials" elsewhere).
    let isGreater: Bool
    var up = false
    var surfaced = false
    var lastRxMs: UInt64
    var lastPingMs: UInt64
    var txSeq: UInt64 = 0

    init(linkId: LinkId, nodeNum: UInt32, peerId: Data, isGreater: Bool, nowMs: UInt64) {
        self.linkId = linkId; self.nodeNum = nodeNum; self.peerId = peerId
        self.isGreater = isGreater; self.lastRxMs = nowMs; self.lastPingMs = nowMs
    }

    var role: HopRole { isGreater ? .dialer : .acceptor }
    var peerShort: String { shortHex(peerId) }
}

public final class MeshtasticBearer: Bearer {
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). Meshtastic/LoRa links surface as "LoRa".
    public let transportName = "LoRa"

    private let myId: Data
    private let meshQueue = DispatchQueue(label: "hop.mesh")
    private let radio: MeshtasticRadio

    private var myNodeNum: UInt32?
    private var linksByNode = [UInt32: MeshLink]()
    private var linksByLinkId = [LinkId: MeshLink]()
    private let reassembler = MeshReassembler()
    private var nextLinkId: LinkId = 1
    private var nextMsgId: UInt16 = 1
    private var nextPktId: UInt32 = 1
    private var stopped = false
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastBeaconMs: UInt64 = 0
    private var configNonce: UInt32 = 1

    /// Production entry point: talk to a real Meshtastic radio over CoreBluetooth.
    public convenience init(myId: Data) {
        self.init(myId: myId, radio: CoreBluetoothMeshtasticRadio())
    }

    /// Test/injection entry point: drive the state machine against any `MeshtasticRadio`.
    init(myId: Data, radio: MeshtasticRadio) {
        self.myId = myId
        self.radio = radio
    }

    // MARK: - Bearer lifecycle

    public func start() {
        log("STATE", "mesh node-start myId=\(hex(myId)) port=\(MESH_HOP_PORTNUM)")
        meshQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            // Hop every radio callback onto meshQueue so the state machine stays single-threaded no matter
            // which thread the radio delivers on (CoreBluetooth uses its own dispatch queue).
            self.radio.onConnect = { [weak self] in self?.meshQueue.async { self?.onRadioConnected() } }
            self.radio.onDisconnect = { [weak self] in self?.meshQueue.async { self?.onRadioDisconnected() } }
            self.radio.onFromRadio = { [weak self] bytes in self?.meshQueue.async { self?.onFromRadio(bytes) } }
            self.startMaintenance()
            self.radio.start()
        }
    }

    public func stop() {
        meshQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.maintenanceTimer?.cancel(); self.maintenanceTimer = nil
            for link in Array(self.linksByNode.values) { self.teardown(link, why: "stop") }
            self.radio.stop()
        }
    }

    public func send(_ bytes: Data, on link: LinkId) {
        meshQueue.async { [weak self] in
            guard let self, let l = self.linksByLinkId[link] else { return }
            self.shipFrame(MeshFrame.data([UInt8](bytes)), to: l.nodeNum)
        }
    }

    // MARK: - Radio callbacks (all on meshQueue)

    private func onRadioConnected() {
        guard !stopped else { return }
        log("STATE", "mesh radio-connected, requesting config")
        configNonce &+= 1
        radio.send(toRadio: MeshtasticProto.encodeWantConfig(configNonce))
        // Beacon our presence right away so peers already on the mesh learn us without waiting a cycle.
        broadcastHello()
    }

    private func onRadioDisconnected() {
        log("STATE", "mesh radio-disconnected, tearing down \(linksByNode.count) link(s)")
        for link in Array(linksByNode.values) { teardown(link, why: "radio down") }
        myNodeNum = nil
    }

    private func onFromRadio(_ bytes: [UInt8]) {
        guard !stopped else { return }
        guard let inbound = MeshtasticProto.decodeFromRadio(bytes) else { return }
        switch inbound {
        case .myNodeNum(let num):
            if myNodeNum != num { log("STATE", "mesh my-node-num=\(num)") }
            myNodeNum = num
        case .hopData(let from, let payload):
            guard from != 0, from != myNodeNum else { return }   // ignore our own echoes
            guard let body = reassembler.accept(peer: from, fragment: payload, nowS: nowS()) else { return }
            handleFrame(from: from, body: body)
        }
    }

    // MARK: - Hop link-frame handling

    private func handleFrame(from node: UInt32, body: [UInt8]) {
        guard let type = body.first else { return }
        if let l = linksByNode[node] { l.lastRxMs = nowMs() }
        switch type {
        case M_HELLO:
            guard let peerId = MeshFrame.helloPeerId(body) else { return }
            onHello(node: node, peerId: peerId)
        case M_PING:
            // Echo the PING body prefix as a PONG, unicast back to the sender.
            let echo = Array(body[1..<min(17, body.count)])
            shipFrame(MeshFrame.pong(echo: echo), to: node)
        case M_PONG:
            break   // liveness only; lastRxMs already bumped
        case M_DATA:
            guard let l = linksByNode[node], l.up else { return }
            sink?.linkBytes(l.linkId, Data(body.dropFirst()))
        default:
            break
        }
    }

    private func onHello(node: UInt32, peerId: Data) {
        if peerId == myId { return }   // our own HELLO reflected by the mesh
        if let existing = linksByNode[node] {
            existing.peerId = peerId
            existing.lastRxMs = nowMs()
            return
        }
        let isGreater = meshKeepGreaterLeg(myId: myId, peer: peerId)
        let link = MeshLink(linkId: mint(), nodeNum: node, peerId: peerId, isGreater: isGreater, nowMs: nowMs())
        link.up = true
        linksByNode[node] = link
        linksByLinkId[link.linkId] = link
        link.surfaced = true
        log("STATE", "mesh hello-recv peer=\(link.peerShort) node=\(node) greater=\(isGreater)")
        // Answer with a unicast HELLO so the peer learns us even if it missed our broadcast beacon. The
        // role byte carries OUR greater-ness (informational: the peer computes its own from the ids too).
        shipFrame(MeshFrame.hello(myId: myId, isGreater: isGreater), to: node)
        sink?.linkUp(link.linkId, role: link.role, peerId: peerId)
    }

    // MARK: - Outbound

    /// Fragment one Hop link frame and ship every fragment to `dest` (a node num, or MESH_BROADCAST_ADDR).
    /// `from` is left 0 until the radio reports our node num (the radio fills it in that case), so a HELLO
    /// broadcast can go out before config completes.
    private func shipFrame(_ frame: [UInt8], to dest: UInt32) {
        let msgId = nextMsgId; nextMsgId = nextMsgId &+ 1
        guard let frags = meshFragment(frame, msgId: msgId) else {
            log("WARN", "mesh frame too large to fragment (\(frame.count) bytes)")
            return
        }
        let from = myNodeNum ?? 0
        for frag in frags {
            let id = nextPktId; nextPktId = nextPktId &+ 1
            let radioFrame = MeshtasticProto.encodeToRadioPacket(
                from: from, to: dest, id: id, hopLimit: 3, fragment: frag)
            radio.send(toRadio: radioFrame)
        }
    }

    private func broadcastHello() {
        shipFrame(MeshFrame.hello(myId: myId, isGreater: false), to: MESH_BROADCAST_ADDR)
        lastBeaconMs = nowMs()
    }

    // MARK: - Maintenance (beacon, per-link keepalive, dead reap)

    private func startMaintenance() {
        guard maintenanceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: meshQueue)
        timer.schedule(deadline: .now() + MESH_PING_S, repeating: MESH_PING_S)
        timer.setEventHandler { [weak self] in self?.runMaintenance(nowMs()) }
        maintenanceTimer = timer
        timer.resume()
    }

    private func runMaintenance(_ now: UInt64) {
        guard !stopped else { return }
        reassembler.evictStale(nowS: Double(now) / 1000)
        // Rebroadcast our HELLO beacon so newly-arrived mesh peers discover us.
        if Double(now - lastBeaconMs) / 1000 >= MESH_PING_S { broadcastHello() }
        for link in Array(linksByNode.values) {
            if Double(now - link.lastRxMs) / 1000 > MESH_DEAD_S { teardown(link, why: "liveness DEAD"); continue }
            if Double(now - link.lastPingMs) / 1000 >= MESH_PING_S {
                link.lastPingMs = now
                link.txSeq &+= 1
                shipFrame(MeshFrame.ping(seq: link.txSeq, nowMs: now), to: link.nodeNum)
            }
        }
    }

    // MARK: - Teardown

    private func teardown(_ link: MeshLink, why: String) {
        linksByNode.removeValue(forKey: link.nodeNum)
        linksByLinkId.removeValue(forKey: link.linkId)
        reassembler.forget(peer: link.nodeNum)
        log("STATE", "mesh link-down (\(why)) peer=\(link.peerShort) node=\(link.nodeNum)")
        if link.surfaced { sink?.linkDown(link.linkId) }
    }

    private func mint() -> LinkId { let id = nextLinkId; nextLinkId += 1; return id }
}

#if DEBUG
// Test-only seams (DEBUG-only). They call the REAL production paths on `meshQueue` so the integration
// tests drive linkUp/linkBytes/linkDown, fragmentation/reassembly, keepalive and reap with a fake radio
// and an injected clock, with no CoreBluetooth and no Meshtastic hardware. They add NO new behavior.
extension MeshtasticBearer {
    /// Run one maintenance pass at an injected wall clock (ms), exactly as the timer handler would.
    func testRunMaintenance(atMs: UInt64) { meshQueue.sync { self.runMaintenance(atMs) } }

    /// The peer node num of the link the manager assigned `linkId`, or nil.
    func testNodeNum(for linkId: LinkId) -> UInt32? { meshQueue.sync { self.linksByLinkId[linkId]?.nodeNum } }

    var testLinkCount: Int { meshQueue.sync { self.linksByNode.count } }
    var testMyNodeNum: UInt32? { meshQueue.sync { self.myNodeNum } }
}
#endif
