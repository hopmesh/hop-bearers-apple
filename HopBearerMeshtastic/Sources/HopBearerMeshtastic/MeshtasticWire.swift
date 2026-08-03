// MeshtasticWire, the Meshtastic bearer's PURE, radio-free wire logic, split out so it is unit-testable
// on a headless macOS `swift test` with no CoreBluetooth peer and no Meshtastic hardware (the same
// discipline LanWire / CentralCore follow). Everything here is value math: the minimal Meshtastic
// protobuf codec, the fragment/reassembly layer that carries a Hop link frame across many tiny LoRa
// packets, the Hop link-frame grammar (byte-identical to the LAN/BLE bearers), and the one-pipe-per-peer
// dedup keep-rule. MeshtasticBearer.swift (link state) and MeshtasticBearer+Radio.swift (the real GATT
// connection to a Meshtastic radio) build on top of it and are EXCLUDED from the coverage denominator,
// exactly like every other bearer's radio glue.
//
// WHY A SEPARATE TRANSPORT SHAPE. LAN/BLE are byte-stream links: a 4-byte length prefix deframes a
// stream. Meshtastic is the opposite: a datagram mesh of ~200-byte LoRa packets, lossy and airtime
// limited, that RELAYS each packet hop-by-hop across every radio in range. So a Hop link frame (a HELLO,
// or a DATA carrying a sealed Hop record) does not fit one packet and must be FRAGMENTED into
// MESH_MAX_CHUNK-sized pieces, each shipped as one Meshtastic `MeshPacket` on a private app port, and
// REASSEMBLED on the far side keyed by (sender node, message id). The delay-tolerant, store-and-forward
// nature of the mesh is a natural fit for Hop, which is itself delay-tolerant by design.
//
// Hop link-frame grammar (the SAME 1-byte type tags the LAN bearer uses, so the consumer sees identical
// linkUp/linkBytes/linkDown semantics regardless of radio):
//   HELLO 0x01 : [16B nodeId][1B role][1B flags]   role 1 = the greater-id side (the Noise initiator)
//   PING  0x02 : [8B seq][8B nowMs]                 keepalive; never surfaced to the consumer
//   PONG  0x03 : echoes the peer's PING body prefix
//   DATA  0x10 : the consumer's application bytes (a sealed Hop record)
//
// The fragment header prepended to each Meshtastic payload is 4 bytes:
//   [msgId hi][msgId lo][fragIndex][fragCount]      then up to MESH_MAX_CHUNK bytes of the frame body
//
// These constants are a POLICY the bearer implements on BOTH platforms, so per bearers/CLAUDE.md they
// are pinned in `bearers/meshtastic-vectors.json` and asserted by `tools/meshtastic-parity.sh`. Keep the
// two in lockstep; the guard fails CI if Apple and Android drift.

import Foundation
import HopContract   // the bearer contract (no libhop): log/hex/nodeIdGreater helpers

// MARK: - Pinned cross-platform constants (see bearers/meshtastic-vectors.json) --------------------------

/// Meshtastic `PortNum` for Hop traffic. PRIVATE_APP is 256; Hop rides a fixed offset inside the private
/// range (256..511) so it never collides with a first-party Meshtastic app. Both ends must also share a
/// Meshtastic channel (PSK) for the radios to exchange these packets; that is device configuration, not
/// bearer code.
let MESH_HOP_PORTNUM: UInt32 = 260

/// The Meshtastic broadcast node address (0xffffffff). HELLO and PING go to the broadcast address so a
/// peer is discovered without knowing its node num first; DATA and PONG unicast back to the sender.
let MESH_BROADCAST_ADDR: UInt32 = 0xffff_ffff

/// LoRa airtime is scarce, so a Hop record is chunked into at most this many bytes per Meshtastic packet.
/// A Meshtastic `Data.payload` tops out near 237 bytes; 200 leaves headroom for the 4-byte fragment
/// header plus the surrounding protobuf field tags without ever overflowing a single frame.
let MESH_MAX_CHUNK = 200

/// The fixed fragment header size: [msgId:2][fragIndex:1][fragCount:1].
let MESH_FRAG_HEADER = 4

/// A frame body is split across at most 255 fragments (fragCount is one byte), which with MESH_MAX_CHUNK
/// bounds a single reassembled frame at 255 * 200 = 51000 bytes. Larger link frames are refused outright
/// (they would never survive a lossy LoRa mesh anyway).
let MESH_MAX_FRAGS = 255
let MESH_MAX_MESSAGE = MESH_MAX_FRAGS * MESH_MAX_CHUNK

/// Liveness. LoRa is slow and duty-cycle limited, so the keepalive is far lazier than the LAN bearer's
/// 1 Hz: PING every 30 s, declare a peer dead after 180 s of silence. Delay-tolerant by construction.
let MESH_PING_S: Double = 30.0
let MESH_DEAD_S: Double = 180.0

/// A half-assembled inbound message is dropped after this long, so a peer that sends 3 of 5 fragments and
/// vanishes cannot pin reassembly memory forever. Also bounds concurrent partial messages per peer.
let MESH_REASSEMBLY_TTL_S: Double = 120.0
let MESH_MAX_PARTIAL_PER_PEER = 8

// Hop link-frame type tags (identical to the LAN bearer's L_HELLO/L_PING/L_PONG/L_DATA).
let M_HELLO: UInt8 = 0x01
let M_PING: UInt8 = 0x02
let M_PONG: UInt8 = 0x03
let M_DATA: UInt8 = 0x10

// MARK: - Minimal protobuf codec (only the Meshtastic messages the bearer needs) ------------------------

/// A tiny protobuf writer: just varint, fixed32, and length-delimited fields. Meshtastic messages are
/// small and their field numbers are stable, so hand-encoding the exact subset the bearer needs is far
/// lighter than pulling the full generated SDK, and it is FULLY unit-testable byte for byte.
struct ProtoWriter {
    private(set) var bytes = [UInt8]()

    mutating func varintField(_ field: Int, _ value: UInt64) {
        tag(field, 0)
        varint(value)
    }

    mutating func fixed32Field(_ field: Int, _ value: UInt32) {
        tag(field, 5)
        for i in 0..<4 { bytes.append(UInt8((value >> (8 * UInt32(i))) & 0xff)) }   // little-endian
    }

    mutating func bytesField(_ field: Int, _ value: [UInt8]) {
        tag(field, 2)
        varint(UInt64(value.count))
        bytes.append(contentsOf: value)
    }

    private mutating func tag(_ field: Int, _ wire: Int) { varint(UInt64(field << 3 | wire)) }

    private mutating func varint(_ v: UInt64) {
        var value = v
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
    }
}

/// A tiny protobuf reader over a byte slice. Every read is bounds-checked and returns nil on a malformed
/// buffer, so a hostile radio frame can never index out of range. It skips fields the bearer does not
/// care about by wire type.
struct ProtoReader {
    private let buf: [UInt8]
    private var i = 0

    init(_ bytes: [UInt8]) { self.buf = bytes }

    var atEnd: Bool { i >= buf.count }

    /// Read the next field's (fieldNumber, wireType), or nil at end / on a truncated tag.
    mutating func readTag() -> (field: Int, wire: Int)? {
        guard let t = readVarint() else { return nil }
        return (Int(t >> 3), Int(t & 0x7))
    }

    mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < buf.count {
            let byte = buf[i]; i += 1
            if shift > 63 { return nil }                       // overlong varint, refuse
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil                                             // ran off the end mid-varint
    }

    mutating func readFixed32() -> UInt32? {
        guard i + 4 <= buf.count else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 { v |= UInt32(buf[i + k]) << (8 * UInt32(k)) }
        i += 4
        return v
    }

    mutating func readBytes() -> [UInt8]? {
        guard let len = readVarint(), i + Int(len) <= buf.count else { return nil }
        let out = Array(buf[i..<i + Int(len)])
        i += Int(len)
        return out
    }

    /// Skip a field of the given wire type (used for fields the bearer ignores). Returns false if the
    /// buffer is malformed. Wire type 1 (64-bit) and 5 (32-bit) are fixed widths; 0 is a varint; 2 is
    /// length-delimited. Groups (3/4) are obsolete and treated as malformed.
    mutating func skip(_ wire: Int) -> Bool {
        switch wire {
        case 0: return readVarint() != nil
        case 1: guard i + 8 <= buf.count else { return false }; i += 8; return true
        case 2: return readBytes() != nil
        case 5: return readFixed32() != nil
        default: return false
        }
    }
}

// MARK: - Meshtastic messages (the exact subset the bearer speaks) --------------------------------------

/// The inbound Meshtastic payload the bearer cares about after decoding one `FromRadio`: either the
/// radio told us our own node number, or a data packet arrived on the Hop port from some peer node.
enum MeshInbound: Equatable {
    case myNodeNum(UInt32)
    case hopData(from: UInt32, payload: [UInt8])
}

enum MeshtasticProto {
    // Field numbers from the stable Meshtastic mesh.proto. Wire types matter: from/to/id are `fixed32`,
    // portnum/channel/hop_limit are varints, decoded/payload are length-delimited.
    //   Data:       portnum=1 (varint), payload=2 (bytes)
    //   MeshPacket: from=1 (fixed32), to=2 (fixed32), channel=3 (varint), decoded=4 (Data),
    //               id=6 (fixed32), hop_limit=9 (varint), want_ack=10 (varint/bool)
    //   ToRadio:    packet=1 (MeshPacket), want_config_id=3 (varint)
    //   FromRadio:  packet=2 (MeshPacket), my_info=3 (MyNodeInfo)
    //   MyNodeInfo: my_node_num=1 (varint)

    /// Encode a Meshtastic `Data` submessage carrying one Hop fragment on the Hop port.
    static func encodeData(payload: [UInt8]) -> [UInt8] {
        var w = ProtoWriter()
        w.varintField(1, UInt64(MESH_HOP_PORTNUM))   // portnum
        w.bytesField(2, payload)                      // payload
        return w.bytes
    }

    /// Encode a `ToRadio{ packet }` that ships one Hop fragment. `to` is the destination node num
    /// (MESH_BROADCAST_ADDR for HELLO/PING). `id` is a fresh packet id; `hopLimit` bounds mesh relaying.
    static func encodeToRadioPacket(from: UInt32, to: UInt32, id: UInt32, hopLimit: UInt32,
                                    fragment: [UInt8]) -> [UInt8] {
        var pkt = ProtoWriter()
        pkt.fixed32Field(1, from)                     // from
        pkt.fixed32Field(2, to)                       // to
        pkt.bytesField(4, encodeData(payload: fragment)) // decoded (Data)
        pkt.fixed32Field(6, id)                       // id
        pkt.varintField(9, UInt64(hopLimit))          // hop_limit
        var radio = ProtoWriter()
        radio.bytesField(1, pkt.bytes)                // ToRadio.packet
        return radio.bytes
    }

    /// Encode the `ToRadio{ want_config_id }` the app sends on connect to make the radio stream its
    /// config + node db + MyNodeInfo (the bearer only needs MyNodeInfo, for our own node num).
    static func encodeWantConfig(_ nonce: UInt32) -> [UInt8] {
        var w = ProtoWriter()
        w.varintField(3, UInt64(nonce))               // want_config_id
        return w.bytes
    }

    /// Decode one `FromRadio` frame into the one thing the bearer acts on, or nil if it is a message the
    /// bearer ignores (config, node_info, log records, ...) or is malformed. Only Hop-port data packets
    /// and MyNodeInfo are surfaced.
    static func decodeFromRadio(_ bytes: [UInt8]) -> MeshInbound? {
        var r = ProtoReader(bytes)
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (2, 2):                              // packet = MeshPacket
                guard let sub = r.readBytes() else { return nil }
                if let inbound = decodeMeshPacket(sub) { return inbound }
            case (3, 2):                              // my_info = MyNodeInfo
                guard let sub = r.readBytes() else { return nil }
                if let num = decodeMyNodeNum(sub) { return .myNodeNum(num) }
            default:
                guard r.skip(wire) else { return nil }
            }
        }
        return nil
    }

    /// Decode a `MeshPacket`, returning a Hop-port data packet as `.hopData(from:payload:)` or nil for
    /// anything else (a different port, an encrypted-only packet we cannot read, a malformed frame).
    static func decodeMeshPacket(_ bytes: [UInt8]) -> MeshInbound? {
        var r = ProtoReader(bytes)
        var from: UInt32 = 0
        var decoded: [UInt8]?
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (1, 5): guard let v = r.readFixed32() else { return nil }; from = v      // from
            case (4, 2): guard let v = r.readBytes() else { return nil }; decoded = v     // decoded (Data)
            default: guard r.skip(wire) else { return nil }
            }
        }
        guard let data = decoded, let payload = decodeHopData(data) else { return nil }
        return .hopData(from: from, payload: payload)
    }

    /// Decode a `Data` submessage, returning its payload IFF it is on the Hop port, else nil.
    static func decodeHopData(_ bytes: [UInt8]) -> [UInt8]? {
        var r = ProtoReader(bytes)
        var portnum: UInt32 = 0
        var payload: [UInt8]?
        while let (field, wire) = r.readTag() {
            switch (field, wire) {
            case (1, 0): guard let v = r.readVarint() else { return nil }; portnum = UInt32(truncatingIfNeeded: v)
            case (2, 2): guard let v = r.readBytes() else { return nil }; payload = v
            default: guard r.skip(wire) else { return nil }
            }
        }
        guard portnum == MESH_HOP_PORTNUM else { return nil }
        return payload ?? []
    }

    /// Decode `MyNodeInfo.my_node_num` (field 1, varint), or nil.
    static func decodeMyNodeNum(_ bytes: [UInt8]) -> UInt32? {
        var r = ProtoReader(bytes)
        while let (field, wire) = r.readTag() {
            if field == 1, wire == 0 { return r.readVarint().map { UInt32(truncatingIfNeeded: $0) } }
            guard r.skip(wire) else { return nil }
        }
        return nil
    }
}

// MARK: - Hop link-frame grammar (identical tags to the LAN bearer) -------------------------------------

enum MeshFrame {
    static func hello(myId: Data, isGreater: Bool) -> [UInt8] {
        var b: [UInt8] = [M_HELLO]
        b.append(contentsOf: myId)
        b.append(isGreater ? 1 : 0)
        b.append(0)
        return b
    }

    static func ping(seq: UInt64, nowMs: UInt64) -> [UInt8] {
        var b: [UInt8] = [M_PING]
        b.append(contentsOf: u64(seq))
        b.append(contentsOf: u64(nowMs))
        return b
    }

    static func pong(echo: [UInt8]) -> [UInt8] { [M_PONG] + echo }

    static func data(_ payload: [UInt8]) -> [UInt8] { [M_DATA] + payload }

    /// The 16-byte peerId a HELLO body carries, or nil if the body is too short.
    static func helloPeerId(_ body: [UInt8]) -> Data? {
        body.count >= 17 ? Data(body[1..<17]) : nil
    }

    static func u64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (56 - $0 * 8)) & 0xff) } }

    static func u64dec(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in 0..<8 where o + k < b.count { v = v << 8 | UInt64(b[o + k]) }
        return v
    }
}

// MARK: - Fragmentation + reassembly --------------------------------------------------------------------

/// Split a Hop link-frame body into fragments that each fit one Meshtastic packet. Every fragment is
/// prefixed with [msgId:2][fragIndex:1][fragCount:1]. An empty body still yields ONE (empty) fragment so
/// a zero-length frame round-trips. Returns nil if the body is larger than MESH_MAX_MESSAGE (too big to
/// address with a one-byte fragment count).
func meshFragment(_ body: [UInt8], msgId: UInt16) -> [[UInt8]]? {
    guard body.count <= MESH_MAX_MESSAGE else { return nil }
    let count = body.isEmpty ? 1 : (body.count + MESH_MAX_CHUNK - 1) / MESH_MAX_CHUNK
    guard count <= MESH_MAX_FRAGS else { return nil }
    var out = [[UInt8]]()
    for idx in 0..<count {
        let start = idx * MESH_MAX_CHUNK
        let end = min(start + MESH_MAX_CHUNK, body.count)
        var frag: [UInt8] = [UInt8(msgId >> 8), UInt8(msgId & 0xff), UInt8(idx), UInt8(count)]
        if start < end { frag.append(contentsOf: body[start..<end]) }
        out.append(frag)
    }
    return out
}

/// The parsed header of one inbound fragment. Returns nil for a runt (< 4 header bytes) or an inconsistent
/// header (index >= count, or count == 0).
struct MeshFragHeader: Equatable {
    let msgId: UInt16
    let index: Int
    let count: Int
    let chunk: [UInt8]

    init?(_ frag: [UInt8]) {
        guard frag.count >= MESH_FRAG_HEADER else { return nil }
        let id = UInt16(frag[0]) << 8 | UInt16(frag[1])
        let idx = Int(frag[2])
        let cnt = Int(frag[3])
        guard cnt >= 1, cnt <= MESH_MAX_FRAGS, idx < cnt else { return nil }
        self.msgId = id
        self.index = idx
        self.count = cnt
        self.chunk = Array(frag[MESH_FRAG_HEADER...])
    }
}

/// Per-peer reassembly of fragmented Hop frames. Keyed by (peer node num, msgId). A message completes when
/// all `count` fragments have arrived; it is evicted if it goes stale (TTL) or the peer exceeds
/// MESH_MAX_PARTIAL_PER_PEER concurrent partials (oldest dropped). Pure: the caller supplies `now` so it
/// is deterministically testable with no clock.
final class MeshReassembler {
    private struct Partial {
        var count: Int
        var chunks: [Int: [UInt8]]
        var firstSeenS: Double
    }

    // node num -> msgId -> Partial
    private var partials = [UInt32: [UInt16: Partial]]()

    /// Feed one inbound fragment from `peer`. Returns the fully reassembled frame body when this fragment
    /// completes a message, else nil. `nowS` is the caller's clock (seconds).
    func accept(peer: UInt32, fragment: [UInt8], nowS: Double) -> [UInt8]? {
        guard let h = MeshFragHeader(fragment) else { return nil }
        evictStale(nowS: nowS)
        var byId = partials[peer] ?? [:]

        // Single-fragment fast path: no state needed. Do not leave an empty per-peer entry behind.
        if h.count == 1 {
            if byId.isEmpty { partials.removeValue(forKey: peer) } else { partials[peer] = byId }
            return h.chunk
        }

        var p = byId[h.msgId] ?? Partial(count: h.count, chunks: [:], firstSeenS: nowS)
        // A count mismatch across fragments of one id means corruption; restart this id from scratch.
        if p.count != h.count { p = Partial(count: h.count, chunks: [:], firstSeenS: nowS) }
        p.chunks[h.index] = h.chunk
        byId[h.msgId] = p

        // Bound concurrent partials per peer: drop the oldest if over budget.
        if byId.count > MESH_MAX_PARTIAL_PER_PEER {
            if let oldest = byId.min(by: { $0.value.firstSeenS < $1.value.firstSeenS })?.key {
                byId.removeValue(forKey: oldest)
            }
        }

        guard p.chunks.count == p.count else { partials[peer] = byId; return nil }

        // Complete: concatenate in index order and drop the partial.
        var body = [UInt8]()
        for idx in 0..<p.count { body.append(contentsOf: p.chunks[idx] ?? []) }
        byId.removeValue(forKey: h.msgId)
        if byId.isEmpty { partials.removeValue(forKey: peer) } else { partials[peer] = byId }
        return body
    }

    /// Drop every peer's partials whose first fragment is older than the TTL.
    func evictStale(nowS: Double) {
        for (peer, byId) in partials {
            var kept = byId
            for (id, p) in byId where nowS - p.firstSeenS > MESH_REASSEMBLY_TTL_S {
                kept.removeValue(forKey: id)
            }
            if kept.isEmpty { partials.removeValue(forKey: peer) } else { partials[peer] = kept }
        }
    }

    /// Forget everything buffered for a peer (called when its link goes down).
    func forget(peer: UInt32) { partials.removeValue(forKey: peer) }

    var partialPeerCount: Int { partials.count }
}

// MARK: - Dedup keep-rule (shared with every other bearer) ----------------------------------------------

/// The one-pipe-per-peer keep rule, identical to the LAN/BLE bearers: on a duplicate pair to one peer,
/// keep the leg whose "I am the greater id" role matches. Meshtastic is a broadcast medium so a true
/// duplicate is rare, but two simultaneous HELLOs can still race; this makes the survivor deterministic
/// and consistent with the id-based role the Noise handshake uses.
func meshKeepGreaterLeg(myId: Data, peer: Data) -> Bool { nodeIdGreater(myId, peer) }
