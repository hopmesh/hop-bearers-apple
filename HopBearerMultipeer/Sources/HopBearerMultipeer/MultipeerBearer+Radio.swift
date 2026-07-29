// The MultipeerConnectivity glue: session/advertiser/browser lifecycle and the three delegate
// conformances. DEVICE-BOUND, so CI cannot exercise it and it is excluded from the coverage
// denominator, exactly like HopBearerBle's CoreBluetooth surface. The decisions worth testing (the
// invite tiebreak, the display-name parse, the link table) live in MultipeerBearer.swift.

import Foundation
import MultipeerConnectivity
import HopContract

extension MultipeerBearer: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {

    // MARK: - Lifecycle

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.buildStack()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.tearDownStack()
            // Tear the link table down too, and tell the consumer. A transport that is stopped but
            // leaves links "up" is worse than one that never came up: the node keeps choosing a path
            // that can no longer carry bytes instead of re-offering over another transport. This is
            // the same rule BearerManager.setEnabled applies when a transport is disabled.
            let orphans = self.peerNameByLink.keys.sorted()
            self.linkByPeer.removeAll()
            self.peerNameByLink.removeAll()
            for id in orphans { self.sink?.linkDown(id) }
        }
    }

    /// Re-attempt advertise/browse and clear the blocked flag. MultipeerConnectivity errors out while
    /// the Local Network prompt is still pending, so the host calls this on foreground to recover
    /// once the user grants permission, with no relaunch.
    public func wake() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.blockedForTest(false)
            self.advertiser?.stopAdvertisingPeer()
            self.browser?.stopBrowsingForPeers()
            if self.advertisingEnabled { self.advertiser?.startAdvertisingPeer() }
            self.browser?.startBrowsingForPeers()
            NSLog("HOPLOG p2p wake advertising=\(self.advertisingEnabled)")
        }
    }

    /// §39 private mode: stop broadcasting presence but keep browsing, so we can still reach peers
    /// who do advertise. Persisted so a later start() honours it.
    public func setAdvertising(_ on: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.advertisingEnabled = on
            guard !self.stopped else { return }
            if on { self.advertiser?.startAdvertisingPeer() } else { self.advertiser?.stopAdvertisingPeer() }
        }
    }

    private func buildStack() {
        // Rebuild every time rather than reusing: an MCSession that has been disconnected is not
        // reliably reusable, so a disable/enable cycle must produce a fresh one or the transport
        // comes back looking alive but carrying nothing.
        let pid = MCPeerID(displayName: transportId)
        peerID = pid
        let s = MCSession(peer: pid, securityIdentity: nil, encryptionPreference: .none)
        s.delegate = self
        session = s
        let adv = MCNearbyServiceAdvertiser(peer: pid, discoveryInfo: nil, serviceType: MultipeerBearer.serviceType)
        adv.delegate = self
        if advertisingEnabled { adv.startAdvertisingPeer() }
        advertiser = adv
        let br = MCNearbyServiceBrowser(peer: pid, serviceType: MultipeerBearer.serviceType)
        br.delegate = self
        br.startBrowsingForPeers()
        browser = br
        NSLog("HOPLOG p2p start: \(pid.displayName) advertising=\(advertisingEnabled)")
    }

    private func tearDownStack() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        peerID = nil
    }

    func sendToPeer(named name: String, _ bytes: Data) {
        guard let s = session, let peer = s.connectedPeers.first(where: { $0.displayName == name }) else { return }
        try? s.send(bytes, toPeers: [peer], with: .reliable)
    }

    // MARK: - Advertiser

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return invitationHandler(false, nil) }
            invitationHandler(true, self.session) // accept; role arbitration is on the browser side
        }
    }

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("HOPLOG p2p advertise failed: \(error.localizedDescription)")
        queue.async { [weak self] in self?.blockedForTest(true) }
    }

    // MARK: - Browser

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        queue.async { [weak self] in
            guard let self, !self.stopped, let me = self.peerID, let s = self.session else { return }
            guard MultipeerBearer.shouldInvite(me: me.displayName, peer: peerID.displayName) else { return }
            browser.invitePeer(peerID, to: s, withContext: nil, timeout: 15)
        }
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("HOPLOG p2p browse failed: \(error.localizedDescription)")
        queue.async { [weak self] in self?.blockedForTest(true) }
    }

    // MARK: - Session

    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let name = peerID.displayName
            switch state {
            case .connected:
                guard let link = self.noteConnected(peerName: name) else { return }
                // The role must match the invite tiebreak, or both sides would play Noise initiator.
                let role: HopRole = MultipeerBearer.shouldInvite(me: self.transportId, peer: name) ? .dialer : .acceptor
                let pid = MultipeerBearer.peerId(fromDisplayName: name) ?? Data()
                self.sink?.linkUp(link, role: role, peerId: pid)
            case .notConnected:
                guard let link = self.noteDisconnected(peerName: name) else { return }
                self.sink?.linkDown(link)
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self, let link = self.linkId(forPeer: peerID.displayName) else { return }
            self.sink?.linkBytes(link, data)
        }
    }

    public func session(_ s: MCSession, didReceive stream: InputStream, withName n: String, fromPeer p: MCPeerID) {}
    public func session(_ s: MCSession, didStartReceivingResourceWithName n: String, fromPeer p: MCPeerID,
                        with progress: Progress) {}
    public func session(_ s: MCSession, didFinishReceivingResourceWithName n: String, fromPeer p: MCPeerID,
                        at localURL: URL?, withError error: Error?) {}
}
