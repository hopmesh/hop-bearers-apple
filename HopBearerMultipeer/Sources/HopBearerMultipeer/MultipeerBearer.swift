// MultipeerBearer — the no-router Wi-Fi P2P transport (MultipeerConnectivity / AWDL) as its OWN
// library (depends only on HopBearerCore). It is the Apple counterpart to Android's Wi-Fi Direct:
// two devices form a direct Wi-Fi link with NO shared access point (unlike the LAN bearer, which
// needs a common router). "The network that finds a way" wants this route, so it stays a first-class
// bearer — just isolated behind the same Bearer/LinkSink contract as BLE/LAN/Relay.
//
// It speaks the SAME link grammar the consumer sees from every bearer — linkUp / linkBytes / linkDown
// keyed by a minted LinkId — but it needs NONE of the BLE/LAN plumbing: MCSession already gives us
// reliable, ordered, message-framed delivery and connection state, so there is no 4-byte framing, no
// HELLO frame, and no PING/PONG watchdog here. The peer's 16-byte nodeId rides in its MCPeerID
// displayName (exactly as the LAN bearer puts it in the Bonjour instance name), so identity is known
// on connect without a handshake. One link per peer via the canonical "greater nodeId invites" rule.

import Foundation
import MultipeerConnectivity
import HopContract   // the bearer contract (no libhop)

/// MultipeerConnectivity service type (Bonjour-style; ≤15 chars, [a-z0-9-]). Must match across peers.
let MP_SERVICE_TYPE = "hop-wifi"

public final class MultipeerBearer: NSObject, Bearer {
    private let myId: Data                       // 16-byte transport id (SPEC R11), carried in displayName
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). AWDL/no-router Wi-Fi surfaces as "P2P".
    public let transportName = "P2P"

    // One serial queue owns every MC delegate callback + all link state — single-threaded, no locks
    // (the same discipline the LAN bearer gets from `lanQueue`).
    private let mpQueue = DispatchQueue(label: "hop.multipeer")
    private let me: MCPeerID
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var linkByPeer = [MCPeerID: LinkId]()
    private var peerByLink = [LinkId: MCPeerID]()
    private var nextLinkId: LinkId = 1

    public init(myId: Data) {
        self.myId = myId
        self.me = MCPeerID(displayName: hex(myId))   // displayName IS our nodeId (like the LAN Bonjour name)
        super.init()
    }

    public func start() {
        mpQueue.async { [weak self] in
            guard let self else { return }
            let s = MCSession(peer: self.me, securityIdentity: nil, encryptionPreference: .none)
            s.delegate = self
            self.session = s
            let adv = MCNearbyServiceAdvertiser(peer: self.me, discoveryInfo: nil, serviceType: MP_SERVICE_TYPE)
            adv.delegate = self
            adv.startAdvertisingPeer()
            self.advertiser = adv
            let br = MCNearbyServiceBrowser(peer: self.me, serviceType: MP_SERVICE_TYPE)
            br.delegate = self
            br.startBrowsingForPeers()
            self.browser = br
            log("STATE", "multipeer node-start myId=\(hex(self.myId)) service=\(MP_SERVICE_TYPE)")
        }
    }

    public func stop() {
        mpQueue.async { [weak self] in
            guard let self else { return }
            self.advertiser?.stopAdvertisingPeer(); self.advertiser = nil
            self.browser?.stopBrowsingForPeers(); self.browser = nil
            let live = Array(self.peerByLink.keys)
            self.session?.disconnect(); self.session = nil
            self.linkByPeer.removeAll(); self.peerByLink.removeAll()
            for link in live { self.sink?.linkDown(link) }
        }
    }

    public func send(_ bytes: Data, on link: LinkId) {
        mpQueue.async { [weak self] in
            guard let self, let peer = self.peerByLink[link], let s = self.session else { return }
            try? s.send(bytes, toPeers: [peer], with: .reliable)   // MCSession preserves message boundaries
        }
    }

    private func mint() -> LinkId { let id = nextLinkId; nextLinkId += 1; return id }

    /// Parse a peer's 16-byte nodeId back out of its MCPeerID displayName (32 hex chars).
    private func peerNodeId(_ p: MCPeerID) -> Data? {
        let name = p.displayName
        guard name.count == 32 else { return nil }
        var d = Data(capacity: 16); var i = name.startIndex
        while i < name.endIndex {
            let j = name.index(i, offsetBy: 2)
            guard let byte = UInt8(name[i..<j], radix: 16) else { return nil }
            d.append(byte); i = j
        }
        return d.count == 16 ? d : nil
    }
}

// MARK: - MC delegates (all state hops onto mpQueue so the bearer stays single-threaded) -------------

extension MultipeerBearer: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

    // Advertiser: a peer invited us. Accept — the inviter (the greater nodeId) already arbitrated the
    // single link per pair, so the acceptor never needs to second-guess.
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        mpQueue.async { [weak self] in invitationHandler(true, self?.session) }
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        log("STATE", "multipeer advertise-FAILED \(error.localizedDescription)")
    }

    // Browser: found a peer. Only the GREATER nodeId invites, so each pair forms exactly one link
    // (the canonical tiebreaker the BLE + LAN bearers also use).
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        mpQueue.async { [weak self] in
            guard let self, let s = self.session else { return }
            guard let peer = self.peerNodeId(peerID), peer != self.myId else { return }
            guard nodeIdGreater(self.myId, peer) else { return }            // greater invites
            guard self.linkByPeer[peerID] == nil else { return }            // already linked/inviting
            log("STATE", "multipeer discovered peer=\(shortHex(peer)) -> INVITE")
            browser.invitePeer(peerID, to: s, withContext: nil, timeout: 15)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        log("STATE", "multipeer browse-FAILED \(error.localizedDescription)")
    }

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        mpQueue.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                guard self.linkByPeer[peerID] == nil else { return }       // dedup: one link per peer
                guard let peer = self.peerNodeId(peerID) else { return }    // ignore non-Hop peers
                let id = self.mint()
                self.linkByPeer[peerID] = id
                self.peerByLink[id] = peerID
                let role: HopRole = nodeIdGreater(self.myId, peer) ? .dialer : .acceptor  // greater invited
                log("STATE", "multipeer link-up peer=\(shortHex(peer)) role=\(role)")
                self.sink?.linkUp(id, role: role, peerId: peer)
            case .notConnected:
                if let id = self.linkByPeer.removeValue(forKey: peerID) {
                    self.peerByLink.removeValue(forKey: id)
                    log("STATE", "multipeer link-down peer=\(peerID.displayName.prefix(8))")
                    self.sink?.linkDown(id)
                }
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        mpQueue.async { [weak self] in
            guard let self, let id = self.linkByPeer[peerID] else { return }
            self.sink?.linkBytes(id, data)                                  // one MCSession message = one DATA blob
        }
    }

    // Unused stream/resource transfer modes (we only use reliable messages).
    public func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    public func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID, with progress: Progress) {}
    public func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID, at u: URL?, withError e: Error?) {}
}
