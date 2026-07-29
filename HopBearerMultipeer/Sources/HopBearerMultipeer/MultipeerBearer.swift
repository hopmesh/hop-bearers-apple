// MultipeerBearer, the Apple peer-to-peer transport behind the shared `Bearer` contract.
//
// WHY THIS PACKAGE EXISTS. Every other Apple transport (BLE, LAN, relay) was extracted behind
// `Bearer`/`LinkSink` and registered with `BearerManager`; Multipeer alone stayed inside the driver,
// minting its own link ids from a 10_000 base and routing through an `mcPeerByLink` dictionary. The
// consequence was not cosmetic: because it never passed through the manager, it could not be
// switched off at runtime, and MultipeerConnectivity carries local traffic on Apple devices. With no
// switch there was no way to prove a delivery actually rode BLE rather than Wi-Fi.
//
// This file holds the headlessly-testable half: the link table, the invite tiebreak, and the
// display-name parse. The MCSession / advertiser / browser glue is in MultipeerBearer+Radio.swift,
// which CI cannot run and the device workflow covers.

import Foundation
import MultipeerConnectivity
import HopContract

// Inherits NSObject because the three MultipeerConnectivity delegate protocols are Objective-C
// protocols and Swift cannot declare NSObjectProtocol conformance on a plain class.
public final class MultipeerBearer: NSObject, Bearer {
    /// The Bonjour service type. MUST stay byte-identical to the value the app declares under
    /// `NSBonjourServices` in its Info.plist (`_hop-mesh._tcp` / `_hop-mesh._udp`): iOS silently
    /// refuses to browse or advertise a service the app has not declared, and the failure looks like
    /// "no peers ever appear" rather than an error. Pinned by a test for that reason.
    public static let serviceType = "hop-mesh"

    public weak var sink: LinkSink?

    /// The short UI tag, and now also the handle `BearerManager.setEnabled` matches on. "P2P" is the
    /// string the driver and both demo apps already map to the Peer-to-Peer row and its icon, so
    /// adopting it here makes the transport toggleable with no UI change.
    public let transportName = "P2P"

    /// The MCPeerID display name we advertise. Deliberately a random per-process transport id and
    /// NEVER the node address (apple-03): the Bonjour/AWDL display name is broadcast in cleartext to
    /// every nearby observer, so carrying the stable address there would let a passive listener
    /// harvest and correlate the device across locations, which is exactly what §39 exists to deny.
    /// Node identity is still established over Noise on the link, the same as BLE.
    public let transportId: String

    /// Everything below is owned by this queue. MultipeerConnectivity delivers its callbacks on
    /// framework-internal queues, and the pre-extraction code hopped each one to main and mutated
    /// driver state there; funnelling through one serial queue is what makes the link table safe
    /// without the driver's involvement.
    let queue = DispatchQueue(label: "hop.mc")

    var linkByPeer: [String: LinkId] = [:]     // display name -> our local link id
    var peerNameByLink: [LinkId: String] = [:]
    private var nextLinkId: LinkId = 1

    /// Set by the host for §39 private mode: browse (so we can still reach peers who advertise) but
    /// do not advertise ourselves. Persisted rather than applied once, so a later `start()` (from the
    /// transport being re-enabled) honours it instead of silently re-advertising.
    var advertisingEnabled = true

    /// True once the framework reported it could not advertise or browse. MultipeerConnectivity
    /// errors out while the Local Network prompt is still pending, so the host calls `wake` on
    /// foreground to recover once permission is granted, with no relaunch.
    public private(set) var blocked = false

    var stopped = false

    // The MultipeerConnectivity objects. Declared here (not in the +Radio extension) because Swift
    // does not allow stored properties in an extension; the extension owns their lifecycle.
    var session: MCSession?
    var advertiser: MCNearbyServiceAdvertiser?
    var browser: MCNearbyServiceBrowser?
    var peerID: MCPeerID?

    /// Set `blocked` from the queue. Named for its test use, but it is the only writer: `blocked` is
    /// published to the host so a UI can say "Local Network permission is pending" rather than
    /// silently showing a dead transport.
    func blockedForTest(_ on: Bool) { blocked = on }

    public init(myId: Data) {
        self.transportId = HopContract.hex(HopContract.randomNodeId())
        _ = myId // identity is negotiated over Noise; the display name must not carry it (apple-03)
        super.init()
    }

    /// Test seam: construct with a fixed transport id so the invite tiebreak can be driven deterministically.
    init(transportId: String) {
        self.transportId = transportId
        super.init()
    }

    // MARK: - Bearer

    public func send(_ bytes: Data, on link: LinkId) {
        queue.async { [weak self] in
            guard let self, let name = self.peerNameByLink[link] else { return }
            self.sendToPeer(named: name, bytes)
        }
    }

    // MARK: - Pure logic (headlessly testable)

    /// Which side invites, so a pair forms ONE session with a clear initiator/responder matching the
    /// Noise XX roles rather than both inviting and racing.
    ///
    /// NOTE THE DIRECTION. This is `me < peer`, i.e. the lexicographically SMALLER id invites, which
    /// is the opposite of the BLE/LAN dedup tiebreak where the greater id dials. That asymmetry is
    /// preserved verbatim from the in-driver implementation ON PURPOSE: flipping it is a symmetric
    /// change that only works if both devices flip at once, so it cannot ride an extraction that must
    /// stay wire-compatible with already-installed builds. Unify it in a separate, deliberate change.
    static func shouldInvite(me: String, peer: String) -> Bool { me < peer }

    /// Parse a peer id out of an MCPeerID display name. The name is 32 lowercase hex characters (16
    /// bytes) minted by `randomNodeId`; anything else is a foreign advertiser on the same service
    /// type and is ignored rather than trusted.
    static func peerId(fromDisplayName name: String) -> Data? {
        guard name.count == 32 else { return nil }
        var out = Data(capacity: 16)
        var idx = name.startIndex
        while idx < name.endIndex {
            let next = name.index(idx, offsetBy: 2)
            guard let byte = UInt8(name[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Mint the next LOCAL link id. Local ids start at 1 because `BearerManager` translates every one
    /// into a process-global id from its own base; the old in-driver 10_000 offset existed only to
    /// keep the driver's hand-rolled id spaces from colliding, and is exactly the bookkeeping this
    /// extraction removes.
    func mint() -> LinkId {
        let id = nextLinkId
        nextLinkId += 1
        return id
    }

    /// A peer reached `.connected`. Returns the link id to surface, or nil if we already hold one for
    /// this peer (Multipeer can report the same peer connected twice; a duplicate must not mint a
    /// second link the consumer would treat as a distinct path).
    func noteConnected(peerName: String) -> LinkId? {
        guard linkByPeer[peerName] == nil else { return nil }
        let id = mint()
        linkByPeer[peerName] = id
        peerNameByLink[id] = peerName
        return id
    }

    /// A peer left. Returns the link id to tear down, or nil if we held none.
    func noteDisconnected(peerName: String) -> LinkId? {
        guard let id = linkByPeer.removeValue(forKey: peerName) else { return nil }
        peerNameByLink[id] = nil
        return id
    }

    func linkId(forPeer name: String) -> LinkId? { linkByPeer[name] }
}
