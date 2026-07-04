// BleBearer — the PROVEN clean-room BLE transport (ble-lab/SPEC.md §8), extracted verbatim behind
// the `Bearer`/`LinkSink` contract so the clean room (Sources/blepeer) and (later) the production app
// share ONE transport. This file is a re-seam of ble-lab/apple/HopBleLab.swift, NOT a re-tune:
//
//   • KEPT IN THE TRANSPORT (unchanged behavior): 4-byte BE framing; the 1 Hz PING *as a keepalive*
//     that feeds the watchdog + STATUS counters; the adaptive liveness watchdog (DEAD_FG_S/DEAD_BG_S)
//     + no-HELLO reaper; the HELLO identity handshake; one-pipe-per-peer dedup (`linksByPeerId` +
//     greater-nodeId keep rule); and the Central redial logic INCLUDING the `retained[id]` guard.
//
//   • LIFTED OUT TO THE CONSUMER: the per-second PROOF counters + `log("PROOF", …)` line. Those now
//     live in the clean-room ProofSink (Sources/blepeer) which pings over DATA frames via Bearer.send.
//     The transport instead drives the sink: `linkUp` on HELLO, `linkBytes` on a DATA frame, `linkDown`
//     on close. The keepalive PING/PONG frames stay transport-internal and NEVER surface as linkBytes.
//
// Wire format (HELLO/PING/PONG/DATA + 4-byte BE length) is preserved byte-for-byte so a HopBearers
// node still interops with the un-refactored Android / hopmac peers. Pure CoreBluetooth/Foundation.

import Foundation
import CoreBluetooth
import Security
import HopContract   // the bearer contract (no libhop)
#if os(iOS)
import CoreLocation   // CLBeaconRegion — the iBeacon EMISSION payload (iOS-only)
#endif

// MARK: - Fresh service scheme (SPEC §1.1) -------------------------------------------------------

let SERVICE_UUID  = CBUUID(string: "7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")   // advertised + GATT service
let ENDPOINT_CHAR = CBUUID(string: "7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")   // GATT READ -> [2B PSM BE][16B nodeId]
let MFG_COMPANY_ID: UInt16 = 0xFFFF                                          // "reserved for testing" company id

let RESTORE_ID_PERIPHERAL = "hoplab.ble.peripheral"
let RESTORE_ID_CENTRAL    = "hoplab.ble.central"

// SPEC §5 timing.
let PING_S: Double  = 1.0     // 1 Hz PING == the keepalive that feeds the watchdog + STATUS counters
let DEAD_FG_S: Double = 5.0   // foreground liveness deadline
let DEAD_BG_S: Double = 15.0  // background liveness deadline (iOS relaxes conn interval in bg)
let REAP_S: Double  = 3.0     // half-open (no-HELLO) reaper
let WAIT_BASE_S: Double = 4.0 // wait-timeout safety net (SPEC §2.2)
let DIAL_TIMEOUT_S: Double = 12.0
let MAX_FRAME = 4 * 1024 * 1024
let STABLE_UP_MS: UInt64 = 30_000
let LOST_S: Double = 30.0

// Wire frame types (SPEC §4). The DATA type is the consumer seam: Bearer.send wraps the consumer's
// application bytes in a DATA frame, and an inbound DATA frame is delivered via sink.linkBytes. The
// PING/PONG types are the transport's own keepalive and never reach the consumer.
let FRAME_HELLO: UInt8 = 0x01
let FRAME_PING:  UInt8 = 0x02
let FRAME_PONG:  UInt8 = 0x03
let FRAME_DATA:  UInt8 = 0x10

// MARK: - Platform config (SPEC §8 / §8.1). Overridable by the iOS app BEFORE BleBearer.start() ---
//
// CLI default: everything on .main (no UI contends — SPEC R8). An iOS app instead points bleQueue at
// a dedicated serial queue and bleRunLoop at a dedicated I/O thread's RunLoop, and sets
// bleAppInBackground from scenePhase. Public mutable globals so the host (app) reassigns them BEFORE
// BleBearer.start() without editing the package.
public var bleQueue: DispatchQueue = .main
public var bleRunLoop: RunLoop = .main
public var bleAppInBackground = false

// MARK: - Small helpers -------------------------------------------------------------------------
// log / nowMs / nowS / hex / shortHex now live in HopBearerCore (shared by every bearer + consumer).

/// Unsigned big-endian compare: a > b (byte 0 most significant). SPEC §1.2 tiebreaker primitive.
func gt(_ a: Data, _ b: Data) -> Bool {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] { return a[i] > b[i] }
    return a.count > b.count
}

// MARK: - Link: one L2CAP channel, 4-byte BE framing, 1 Hz PING (keepalive), adaptive watchdog -----
// SPEC §4 framing, §3.3 HELLO, §5 keepalive/liveness.

final class Link: NSObject, StreamDelegate {
    let linkId: LinkId                              // monotonic id minted by the bearer; the sink's key
    let isDialer: Bool
    let myId: Data
    private(set) var peerId: Data?                  // learned from HELLO; the dedup/tiebreak key
    private(set) var up = false

    // CRITICAL: retain the CBL2CAPChannel for the link's whole life. inputStream/outputStream are
    // just views onto the channel's socket fd; if the channel deallocs, that fd is closed and the
    // streams immediately fail with POSIX EBADF (Bad file descriptor) right after openCompleted.
    // (Android's Link stores the BluetoothSocket for the same reason.)
    private let channel: CBL2CAPChannel
    private let input: InputStream
    private let output: OutputStream
    private var inBuf = [UInt8]()
    private var outBuf = [UInt8]()

    private var lastRxMs = nowMs()
    private let openedMs = nowMs()
    private var becameUpMs: UInt64?
    private var ewmaGapMs = 1000.0                  // inbound inter-arrival EWMA (SPEC R7)
    private var txSeq: UInt64 = 0                   // our keepalive PING counter (STATUS tx)
    private var rxSeq: UInt64 = 0                   // peer's keepalive PING counter (STATUS rx)
    private var lastRttMs: UInt64 = 0

    private var ping: Timer?
    private var watchdog: Timer?
    private let onUp: (Link) -> Void
    private let onData: (Link, Data) -> Void
    private let onClose: (Link) -> Void
    private var closed = false
    // CRITICAL: a Link is only inserted into BleBearer.linksByPeerId in onUp — i.e. AFTER the peer's
    // HELLO arrives. Before that, nothing else holds a strong ref (stream delegates are weak; the ping/
    // watchdog timer blocks are [weak self]), so ARC would free the Link milliseconds after didOpen
    // creates it, tearing down the L2CAP streams before HELLO ever completes (the peer sees EOF). So
    // the Link OWNS ITSELF from creation until close(); the reaper guarantees close() within REAP_S.
    private var selfRetain: Link?

    // Read-only views for STATUS / dedup (SPEC §2.3, §6).
    var rx: UInt64 { rxSeq }
    var tx: UInt64 { txSeq }
    var rttMs: UInt64 { lastRttMs }
    var peerShort: String { shortHex(peerId) }
    /// SPEC §6: a link that stayed UP >= 30 s resets backoff.
    var stableUp: Bool { guard let b = becameUpMs else { return false }; return nowMs() - b >= STABLE_UP_MS }

    init(channel: CBL2CAPChannel, linkId: LinkId, isDialer: Bool, myId: Data,
         onUp: @escaping (Link) -> Void, onData: @escaping (Link, Data) -> Void,
         onClose: @escaping (Link) -> Void) {
        self.linkId = linkId
        self.isDialer = isDialer
        self.myId = myId
        self.onUp = onUp
        self.onData = onData
        self.onClose = onClose
        self.channel = channel                 // retain the channel (keeps the socket fd alive)
        self.input = channel.inputStream
        self.output = channel.outputStream
        super.init()

        log("STATE", "channel-open isDialer=\(isDialer) — scheduling streams")
        for s in [input, output] {
            s.delegate = self
            s.schedule(in: bleRunLoop, forMode: .common)
            s.open()
        }
        // HELLO first (SPEC §3.3): [0x01][16B nodeId][1B role][1B flags]
        var hello = Data([FRAME_HELLO]); hello.append(myId); hello.append(isDialer ? 1 : 0); hello.append(0)
        sendFrame(hello)
        log("STATE", "hello-sent isDialer=\(isDialer)")

        let p = Timer(timeInterval: PING_S, repeats: true) { [weak self] _ in self?.sendPing() }
        let w = Timer(timeInterval: 1.0,    repeats: true) { [weak self] _ in self?.tick() }
        bleRunLoop.add(p, forMode: .common)
        bleRunLoop.add(w, forMode: .common)
        ping = p; watchdog = w
        selfRetain = self          // own our lifecycle until close() (see selfRetain decl)
    }

    private func deadLimitS() -> Double {          // SPEC R7: adaptive deadline
        max(bleAppInBackground ? DEAD_BG_S : DEAD_FG_S, 3.0 * ewmaGapMs / 1000.0)
    }

    private func tick() {
        if !up && Double(nowMs() - openedMs) / 1000 > REAP_S { close("no-HELLO reap"); return }
        if up && Double(nowMs() - lastRxMs) / 1000 > deadLimitS() { close("liveness DEAD") }
    }

    private func sendPing() {
        guard !closed else { return }
        txSeq += 1
        var b = Data([FRAME_PING]); appU64(&b, txSeq); appU64(&b, nowMs())   // PING [seq][t_send_ms]
        sendFrame(b)
    }

    /// Bearer.send entry point: wrap the consumer's application bytes in a DATA frame and drain it.
    func sendData(_ bytes: Data) {
        guard !closed else { return }
        var body = Data([FRAME_DATA]); body.append(bytes)
        sendFrame(body)
    }

    private func sendFrame(_ body: Data) {
        guard !closed else { return }
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { outBuf.append(contentsOf: $0) }
        outBuf.append(contentsOf: body)
        drain()
    }

    func close(_ why: String) {
        guard !closed else { return }
        closed = true
        ping?.invalidate(); watchdog?.invalidate()
        for s in [input, output] { s.close(); s.remove(from: bleRunLoop, forMode: .common) }
        // Transport diagnostic (carries the close reason). The consumer-facing "LINK CLOSED" lifecycle
        // line is emitted by the sink consumer via linkDown().
        log("STATE", "link-down (\(why)) peer=\(peerShort) isDialer=\(isDialer)")
        onClose(self)
        selfRetain = nil           // release self — safe to dealloc now (see selfRetain decl)
    }

    func stream(_ s: Stream, handle e: Stream.Event) {
        let which = (s === input) ? "input" : "output"
        switch e {
        case .openCompleted: log("STATE", "stream \(which) openCompleted")        // DIAG
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: drain()
        case .endEncountered: close("stream \(which) .endEncountered")            // DIAG
        case .errorOccurred: close("stream \(which) .errorOccurred err=\(s.streamError.map { String(describing: $0) } ?? "nil")")  // DIAG
        default: break
        }
    }

    private func drain() {
        while !outBuf.isEmpty && output.hasSpaceAvailable {
            let n = output.write(outBuf, maxLength: outBuf.count)
            if n > 0 { outBuf.removeFirst(n) } else { break }
        }
    }

    private func read() {
        var tmp = [UInt8](repeating: 0, count: 16384)
        while input.hasBytesAvailable {
            let n = input.read(&tmp, maxLength: tmp.count)
            if n > 0 { inBuf.append(contentsOf: tmp[0..<n]) } else { break }
        }
        let gap = Double(nowMs() - lastRxMs)
        ewmaGapMs = 0.8 * ewmaGapMs + 0.2 * gap
        lastRxMs = nowMs()
        deframe()
    }

    private func deframe() {
        while inBuf.count >= 4 {
            let len = Int(UInt32(inBuf[0]) << 24 | UInt32(inBuf[1]) << 16 | UInt32(inBuf[2]) << 8 | UInt32(inBuf[3]))
            guard len >= 1, len <= MAX_FRAME else { close("bad len \(len)"); return }
            let total = 4 + len
            guard inBuf.count >= total else { break }
            handle(Array(inBuf[4..<total]))
            inBuf.removeFirst(total)
        }
    }

    private func handle(_ b: [UInt8]) {
        guard let type = b.first else { return }
        switch type {
        case FRAME_HELLO:                          // HELLO -> [16B nodeId][1B role][1B flags]
            if b.count >= 17 {
                peerId = Data(b[1..<17])
                if !up {
                    up = true
                    becameUpMs = nowMs()
                    log("STATE", "hello-recv peer=\(peerShort) role=\(b.count > 17 ? Int(b[17]) : -1)")
                    onUp(self)                     // bearer: register, sink.linkUp, then dedup
                }
            }
        case FRAME_PING:                           // keepalive PING -> reply PONG; feeds watchdog + STATUS
            guard b.count >= 9 else { return }
            let seq = u64(b, 1)
            if rxSeq != 0 && seq != rxSeq + 1 { log("WARN", "counter gap \(rxSeq) -> \(seq) peer=\(peerShort)") }
            rxSeq = seq
            var pong = Data([FRAME_PONG]); pong.append(contentsOf: b[1..<min(17, b.count)])
            sendFrame(pong)
            // NOTE: the per-second PROOF line lived here in the clean room; it now lives in the
            // ProofSink consumer (Sources/blepeer), which pings over DATA frames. The keepalive PING
            // stays transport-internal and is never surfaced as linkBytes.
        case FRAME_PONG:                           // PONG echoes our PING -> RTT (reverse direction live)
            if b.count >= 17 { let tSend = u64(b, 9); let now = nowMs(); if now >= tSend { lastRttMs = now - tSend } }
        case FRAME_DATA:                           // DATA -> consumer application bytes (post-type payload)
            onData(self, Data(b.dropFirst()))
        default: break
        }
    }

    private func appU64(_ d: inout Data, _ v: UInt64) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
    }
    private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[o + i]) }
        return v
    }
}

// MARK: - ACCEPTOR (peripheral): listener (session-stable PSM) + GATT char + advertiser ----------
// SPEC §3.1.

/// F-12: how often the peripheral re-checks that it is still discoverable (L2CAP published +
/// advertising) and re-arms if not. ble-lab SPEC §7.1 requires this periodic self-heal; without it a
/// publish/advertise error, a stopped advertising set, or a system hiccup leaves the device silently
/// undiscoverable-as-peripheral until the app restarts.
private let PERIPHERAL_HEAL_S: Double = 30.0

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    private var pm: CBPeripheralManager!
    private var psm: CBL2CAPPSM = 0
    private var published = false
    private var healScheduled = false
    private var stopped = false
    private let myId: Data
    private let mintLinkId: () -> LinkId
    private let onLink: (Link) -> Void
    private let onData: (Link, Data) -> Void
    private let onClose: (Link) -> Void
    private let onPowerOff: () -> Void
    /// When true, never advertise: still publish the GATT service + L2CAP channel (so a link CAN be
    /// accepted if a peer somehow reaches us) but stay undiscoverable. Used by the central-only host
    /// (hopmac): it scans and dials, but must not itself be found (scan-only test behavior).
    private let suppressAdvertising: Bool
    #if os(iOS)
    /// iBeacon EMISSION (iOS-only). On iOS the service-UUID advert and an iBeacon advert are mutually
    /// exclusive, so we ALTERNATE: ~5s service-UUID (for L2CAP discovery), ~2s iBeacon (to wake nearby
    /// dormant/force-quit apps whose BeaconWake monitors this region). Mirrors the old app's advert cycle.
    private var advTimer: DispatchSourceTimer?
    private var advCounter = 0
    private var advBeaconNow = false
    #endif

    init(myId: Data, suppressAdvertising: Bool, mintLinkId: @escaping () -> LinkId,
         onLink: @escaping (Link) -> Void, onData: @escaping (Link, Data) -> Void,
         onClose: @escaping (Link) -> Void, onPowerOff: @escaping () -> Void) {
        self.myId = myId; self.suppressAdvertising = suppressAdvertising; self.mintLinkId = mintLinkId
        self.onLink = onLink; self.onData = onData; self.onClose = onClose; self.onPowerOff = onPowerOff
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: bleQueue,
                                 options: [CBPeripheralManagerOptionRestoreIdentifierKey: RESTORE_ID_PERIPHERAL])
        scheduleSelfHeal()   // F-12: keep the advertiser/L2CAP re-armed
    }

    func stop() {
        stopped = true
        guard let pm = pm else { return }
        #if os(iOS)
        advTimer?.cancel(); advTimer = nil
        #endif
        pm.stopAdvertising()
        if published { pm.unpublishL2CAPChannel(psm); published = false }
        pm.removeAllServices()
    }

    // F-12: periodic self-heal (ble-lab SPEC §7.1). If we're powered on but not published, republish
    // the L2CAP channel (which re-triggers advertising on success); if published but not advertising,
    // restart advertising. This is what recovers a wedged/stopped advertiser or a failed publish —
    // the delegate error handlers just log, this loop is what actually retries.
    private func scheduleSelfHeal() {
        guard !healScheduled else { return }
        healScheduled = true
        bleQueue.asyncAfter(deadline: .now() + PERIPHERAL_HEAL_S) { [weak self] in
            guard let self else { return }
            self.healScheduled = false
            self.selfHeal()
            if !self.stopped { self.scheduleSelfHeal() }
        }
    }

    private func selfHeal() {
        guard !stopped, let pm = pm, pm.state == .poweredOn else { return }
        if ProcessInfo.processInfo.environment["HOPLAB_NO_ADV"] != nil { return }  // central-only diagnostic
        if !published {
            log("STATE", "peripheral self-heal: republishing L2CAP")
            pm.publishL2CAPChannel(withEncryption: false)
        } else if !pm.isAdvertising {
            log("STATE", "peripheral self-heal: restarting advertising")
            pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])
        }
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        log("STATE", "peripheral state=\(stateName(p.state))")
        if p.state == .poweredOff { onPowerOff(); published = false; return }   // SPEC R11
        guard p.state == .poweredOn else { return }
        let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil, permissions: .readable)
        let svc = CBMutableService(type: SERVICE_UUID, primary: true)
        svc.characteristics = [ch]
        p.add(svc)
        log("STATE", "peripheral gatt-service-added")
        p.publishL2CAPChannel(withEncryption: false)                            // INSECURE CoC (SPEC §1.1)
    }

    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            // `published` stays false, so the F-12 self-heal loop retries publish shortly.
            log("STATE", "peripheral l2cap-publish-FAILED \(error.localizedDescription) — self-heal will retry")
            return
        }
        psm = PSM
        published = true
        log("STATE", "peripheral l2cap-published psm=\(psm)")
        // Central-only host (hopmac) OR the legacy DIAG env var: publish everything but stay
        // undiscoverable (no advertising at all).
        if suppressAdvertising || ProcessInfo.processInfo.environment["HOPLAB_NO_ADV"] != nil {
            log("STATE", "peripheral advertising-SUPPRESSED (central-only) — publish-only, no advertising")
            return
        }
        #if os(iOS)
        // iOS: alternate service-UUID advert (L2CAP discovery) with an iBeacon advert (background wake).
        startAdvertisingCycle(p)
        #else
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])  // UUID only on Apple (SPEC §1.3)
        log("STATE", "peripheral advertising-started service=\(SERVICE_UUID.uuidString)")
        #endif
    }

    #if os(iOS)
    /// Advertise on a ~7s cycle: ~5s service-UUID (peers discover us + read the PSM to open L2CAP),
    /// ~2s iBeacon (nearby dormant/force-quit apps monitoring BEACON_UUID get woken). The two advert
    /// forms are mutually exclusive on iOS, so we swap between them instead of running both at once.
    private func startAdvertisingCycle(_ p: CBPeripheralManager) {
        applyAdvertising(p, beacon: false)
        let t = DispatchSource.makeTimerSource(queue: bleQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self, weak p] in
            guard let self, let p else { return }
            self.advCounter = (self.advCounter + 1) % 7
            let wantBeacon = self.advCounter >= 5   // ~2s beacon out of every 7s
            if wantBeacon != self.advBeaconNow {
                self.advBeaconNow = wantBeacon
                self.applyAdvertising(p, beacon: wantBeacon)
            }
        }
        advTimer?.cancel()
        advTimer = t
        t.resume()
    }

    /// Emit either the service-UUID advert (so peers can discover + read the PSM) or the iBeacon advert
    /// (wake). The iBeacon payload is built the way the old app did: `CLBeaconRegion(uuid: BEACON_UUID,
    /// identifier: "hop").peripheralData(withMeasuredPower: nil)`, byte-matching what Android emits.
    private func applyAdvertising(_ p: CBPeripheralManager, beacon: Bool) {
        guard p.state == .poweredOn else { return }
        p.stopAdvertising()
        if beacon {
            let region = CLBeaconRegion(uuid: BEACON_UUID, identifier: "hop")
            if let data = region.peripheralData(withMeasuredPower: nil) as? [String: Any] {
                p.startAdvertising(data)
                return
            }
        }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])  // UUID only on Apple (SPEC §1.3)
    }
    #endif

    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        // On failure `isAdvertising` stays false, so the F-12 self-heal loop restarts advertising.
        if let error { log("STATE", "peripheral advertising-FAILED \(error.localizedDescription) — self-heal will retry") }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        var v = Data([UInt8(psm >> 8), UInt8(psm & 0xff)])                       // [2B PSM BE]
        v.append(myId)                                                          // [16B nodeId]
        req.value = v
        p.respond(to: req, withResult: .success)
        log("STATE", "peripheral read-request -> psm=\(psm) id=\(shortHex(myId))")
    }

    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error { log("STATE", "peripheral inbound-l2cap-FAILED \(error.localizedDescription)"); return }
        guard let channel else { return }
        log("STATE", "peripheral inbound-l2cap-open (acceptor)")
        // SPEC §8.1 iOS adaptation: hand the channel to the I/O thread so that
        // Stream.schedule(in: bleRunLoop) and Timer additions run on the thread that
        // owns bleRunLoop (safe per CFRunLoop thread-affinity rules). No-op when
        // bleRunLoop == .main (the macOS CLI default), since perform fires inline.
        let myId = self.myId, mintLinkId = self.mintLinkId, onLink = self.onLink, onData = self.onData, onClose = self.onClose
        bleRunLoop.perform {
            _ = Link(channel: channel, linkId: mintLinkId(), isDialer: false, myId: myId,
                     onUp: onLink, onData: onData, onClose: onClose)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // SPEC R10: after a system-initiated relaunch, CoreBluetooth restores our services and the
        // published L2CAP channel, then calls peripheralManagerDidUpdateState(.poweredOn) which
        // re-adds the service + republishes; the F-12 self-heal loop then guarantees advertising is
        // (re)started even if that path hiccups. Reset `published` so the heal loop re-publishes if
        // the restored channel isn't actually live.
        log("STATE", "peripheral willRestoreState — re-arm on poweredOn + self-heal")
        published = false
    }
}

// MARK: - DIALER (central): scan -> connect -> read PSM/id -> openL2CAPChannel --------------------
// SPEC §3.2.

final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var cm: CBCentralManager!
    private let myId: Data

    private var retained = [UUID: CBPeripheral]()      // strong ref while dialing/linked (SPEC §3.2.3)
    private var dialTimers = [UUID: DispatchWorkItem]()  // SPEC R6: 12 s dial-timeout per peer
    private var pendingWaits = Set<UUID>()             // SPEC R4: one outstanding wait per peer
    private var advPrefixById = [UUID: Data]()         // backoff-key source (prefix once known)
    private var backoff = [String: Double]()           // SPEC R2: key = 6B-prefix hex (stable), else identifier

    private let mintLinkId: () -> LinkId
    private let onLink: (Link) -> Void
    private let onData: (Link, Data) -> Void
    private let onClose: (Link) -> Void
    private let onPowerOff: () -> Void
    private let haveLinkTo: (Data) -> Bool
    private let haveLinkToPrefix: (Data) -> Bool

    init(myId: Data, mintLinkId: @escaping () -> LinkId,
         onLink: @escaping (Link) -> Void, onData: @escaping (Link, Data) -> Void,
         onClose: @escaping (Link) -> Void, onPowerOff: @escaping () -> Void,
         haveLinkTo: @escaping (Data) -> Bool, haveLinkToPrefix: @escaping (Data) -> Bool) {
        self.myId = myId; self.mintLinkId = mintLinkId
        self.onLink = onLink; self.onData = onData; self.onClose = onClose; self.onPowerOff = onPowerOff
        self.haveLinkTo = haveLinkTo; self.haveLinkToPrefix = haveLinkToPrefix
        super.init()
        cm = CBCentralManager(delegate: self, queue: bleQueue,
                              options: [CBCentralManagerOptionRestoreIdentifierKey: RESTORE_ID_CENTRAL])
    }

    func stop() {
        cm?.stopScan()
        for p in retained.values { cm?.cancelPeripheralConnection(p) }
        dialTimers.values.forEach { $0.cancel() }
        dialTimers.removeAll(); retained.removeAll(); pendingWaits.removeAll()
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("STATE", "central state=\(stateName(c.state))")
        if c.state == .poweredOff { onPowerOff(); return }                      // SPEC R11
        guard c.state == .poweredOn else { return }
        c.scanForPeripherals(withServices: [SERVICE_UUID],                      // filter REQUIRED for bg scan
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("STATE", "central scan-started service=\(SERVICE_UUID.uuidString)")
    }

    /// Background-wake hook (CoreLocation region enter, or app relaunch). Idempotent.
    /// Re-arms the service-filtered scan and pins a no-timeout connect to any peer the
    /// system still considers connected for our service, so the link can complete via
    /// state restoration even if the ~10 s scan window closes first.
    func wake(_ reason: String) {
        guard let cm = cm else { return }
        log("STATE", "WAKE(\(reason)) state=\(stateName(cm.state)) scanning=\(cm.isScanning)")
        guard cm.state == .poweredOn else { return }   // scan auto-starts on .poweredOn
        if !cm.isScanning {
            cm.scanForPeripherals(withServices: [SERVICE_UUID],
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("STATE", "WAKE re-armed scan")
        }
        for p in cm.retrieveConnectedPeripherals(withServices: [SERVICE_UUID]) where retained[p.identifier] == nil {
            log("STATE", "WAKE re-adopt connected id=\(p.identifier.uuidString.prefix(8))")
            dial(cm, p, advPrefixById[p.identifier])
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        var advPrefix: Data? = nil
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8,
           mfg[0] == 0xFF, mfg[1] == 0xFF { advPrefix = mfg.subdata(in: 2..<8) } // 6-byte nodeId prefix
        let bkey = advPrefix.map(hex) ?? p.identifier.uuidString
        if let until = backoff[bkey], nowS() < until { return }                 // SPEC R2: rate-limited
        if let pre = advPrefix, haveLinkToPrefix(pre) { return }                 // SPEC R4: already linked
        guard retained[p.identifier] == nil else { return }                     // already dialing
        let dialNow = advPrefix.map { gt(myId.prefix(6), $0) } ?? true          // SPEC §2.1 (no prefix => dial)
        log("STATE", "discovered id=\(p.identifier.uuidString.prefix(8)) prefix=\(advPrefix.map(hex) ?? "none") rssi=\(rssi) decision=\(dialNow ? "DIAL" : "WAIT")")
        if dialNow {
            dial(c, p, advPrefix)
        } else if pendingWaits.insert(p.identifier).inserted {                  // SPEC R4: one wait per peer
            bleQueue.asyncAfter(deadline: .now() + WAIT_BASE_S + Double.random(in: 0...1)) { [weak self] in
                guard let self else { return }
                self.pendingWaits.remove(p.identifier)
                if let pre = advPrefix, self.haveLinkToPrefix(pre) { return }    // SPEC R4: gate on link map
                if self.retained[p.identifier] != nil { return }
                log("STATE", "wait-timeout fired -> dialing id=\(p.identifier.uuidString.prefix(8))")
                self.dial(c, p, advPrefix)
            }
        }
    }

    private func dial(_ c: CBCentralManager, _ p: CBPeripheral, _ advPrefix: Data?) {
        retained[p.identifier] = p
        advPrefixById[p.identifier] = advPrefix
        p.delegate = self
        c.connect(p, options: nil)
        log("STATE", "DIALING id=\(p.identifier.uuidString.prefix(8))")
        let t = DispatchWorkItem { [weak self] in self?.dialTimedOut(p) }       // SPEC R6
        dialTimers[p.identifier] = t
        bleQueue.asyncAfter(deadline: .now() + DIAL_TIMEOUT_S, execute: t)
    }

    private func dialTimedOut(_ p: CBPeripheral) {
        guard retained[p.identifier] != nil else { return }
        log("STATE", "dial-timeout id=\(p.identifier.uuidString.prefix(8))")
        cm.cancelPeripheralConnection(p)                                        // SPEC R6: abort indefinite connect
        reconnect(p)
    }

    private func clearDialTimer(_ p: CBPeripheral) {
        dialTimers[p.identifier]?.cancel(); dialTimers[p.identifier] = nil
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("STATE", "connected id=\(p.identifier.uuidString.prefix(8)) — discoverServices(nil)")
        p.discoverServices(nil)                                                 // SPEC: nil, not [SERVICE_UUID]
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("STATE", "didFailToConnect id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "")")
        reconnect(p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("STATE", "didDisconnect id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "")")
        reconnect(p)
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        log("STATE", "didModifyServices id=\(p.identifier.uuidString.prefix(8)) — re-discover (defeat stale cache)")
        p.discoverServices(nil)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        log("STATE", "services-discovered id=\(p.identifier.uuidString.prefix(8))")
        for s in p.services ?? [] where s.uuid == SERVICE_UUID {
            p.discoverCharacteristics([ENDPOINT_CHAR], for: s)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] where ch.uuid == ENDPOINT_CHAR {
            log("STATE", "char-discovered -> readValue id=\(p.identifier.uuidString.prefix(8))")
            p.readValue(for: ch)
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value, v.count >= 18 else {
            log("STATE", "read-FAILED id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "short value")")
            return
        }
        let peerId = v.subdata(in: 2..<18)
        let psm = CBL2CAPPSM(UInt16(v[0]) << 8 | UInt16(v[1]))
        log("STATE", "read psm=\(psm) peer=\(shortHex(peerId)) id=\(p.identifier.uuidString.prefix(8))")
        if haveLinkTo(peerId) {                                                 // SPEC R4: already linked -> no redundant CoC
            log("STATE", "already-linked -> cancel id=\(p.identifier.uuidString.prefix(8))")
            clearDialTimer(p); cm.cancelPeripheralConnection(p); retained[p.identifier] = nil; return
        }
        advPrefixById[p.identifier] = peerId.prefix(6)                          // SPEC R2: promote to stable nodeId prefix
        log("STATE", "openL2CAPChannel psm=\(psm) id=\(p.identifier.uuidString.prefix(8))")
        p.openL2CAPChannel(psm)
    }

    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if error != nil {
            log("STATE", "l2cap-open-error -> re-read id=\(p.identifier.uuidString.prefix(8)) \(error!.localizedDescription)")
            p.discoverServices(nil)                                            // stale PSM -> re-read (SPEC §7.4)
            return
        }
        guard let channel else { return }
        clearDialTimer(p)                                                      // SPEC R6: dial succeeded
        backoff[advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString] = nil
        log("STATE", "l2cap-open success (dialer) id=\(p.identifier.uuidString.prefix(8))")
        // SPEC §8.1 iOS adaptation: same as Peripheral.didOpen — construct Link on the
        // I/O thread so streams and timers are bound to the thread owning bleRunLoop.
        let myId = self.myId, mintLinkId = self.mintLinkId, onLink = self.onLink, onData = self.onData, onClose = self.onClose
        let onCloseChain: (Link) -> Void = { [weak self] l in self?.dialerLinkClosed(p, l); onClose(l) }
        bleRunLoop.perform {
            _ = Link(channel: channel, linkId: mintLinkId(), isDialer: true, myId: myId,
                     onUp: onLink, onData: onData, onClose: onCloseChain)
        }
    }

    private func dialerLinkClosed(_ p: CBPeripheral, _ l: Link) {
        let key = advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString
        if l.stableUp { backoff[key] = nil }                                   // SPEC §6: reset after long-lived link
        if retained[p.identifier] != nil { cm.cancelPeripheralConnection(p) }  // -> didDisconnect -> reconnect
    }

    func reconnect(_ p: CBPeripheral) {
        clearDialTimer(p); retained[p.identifier] = nil
        let key = advPrefixById[p.identifier].map(hex) ?? p.identifier.uuidString
        let base = backoff[key].map { max($0 - nowS(), 0.5) } ?? 0.5
        let next = min(base * 2, 30) + Double.random(in: 0...1)                 // SPEC §6 schedule
        backoff[key] = nowS() + next
        log("STATE", "COOLDOWN id=\(p.identifier.uuidString.prefix(8)) backoff=\(String(format: "%.1f", next))s")
        evictBackoff()                                                         // SPEC R2: TTL bound
    }

    private func evictBackoff() {
        let cut = nowS() - LOST_S
        backoff = backoff.filter { $0.value > cut }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log("STATE", "central willRestoreState peripherals=\(restored.count)")
        for p in restored {
            retained[p.identifier] = p        // re-retain BEFORE anything else (SPEC §3.2.3)
            p.delegate = self                 // the system does NOT keep our delegate wiring
            if p.state == .connected {
                p.discoverServices(nil)       // resume the PSM-read handshake
            } else {
                c.connect(p, options: nil)    // re-arm the no-timeout pending connect (Layer B)
            }
        }
        // scan re-arms in centralManagerDidUpdateState(.poweredOn), which fires next.
    }
}

// MARK: - BleBearer: owns myId, both planes, the dedup map + the linkId map (SPEC §2.3) ----------

/// The PROVEN clean-room BLE transport behind the `Bearer` contract. Owns one-pipe-per-peer dedup
/// internally and assigns a monotonic `LinkId` per established Link; the consumer only ever sees
/// linkUp / linkBytes / linkDown and calls `send`.
public final class BleBearer: Bearer {
    private let myId: Data                           // SPEC R11: stable for the whole process lifetime
    /// Where links surface. Set by the consumer (or a BearerManager) before `start()`. Weak: the
    /// sink/manager owns the bearer, so a strong ref back would cycle (see `Bearer.sink`).
    public weak var sink: LinkSink?
    /// Short transport tag for the consumer's UI (Bearer contract). BLE links surface as "BT".
    public let transportName = "BT"
    private var peripheral: Peripheral?
    private var central: Central?
    private var linksByPeerId = [Data: Link]()       // dedup: one survivor per peer (SPEC §2.3)
    private var linksByLinkId = [LinkId: Link]()     // send routing + linkUp/linkDown pairing
    private var nextLinkId: LinkId = 1               // minted on bleRunLoop (single-threaded) — no lock
    private var status: Timer?
    #if os(iOS)
    private var beaconWake: BeaconWake?              // the bearer's own iBeacon background-wake monitor
    #endif

    /// When true, the bearer publishes its GATT/L2CAP endpoint but NEVER advertises, so it can dial
    /// peers (central) yet stay undiscoverable (central-only scan behavior — hopmac). Default false:
    /// the dual-role production bearer advertises so peers can find it.
    private let suppressAdvertising: Bool

    public init(myId: Data, suppressAdvertising: Bool = false) {
        self.myId = myId
        self.suppressAdvertising = suppressAdvertising
    }

    /// Convenience: a fresh random 16-byte nodeId (SPEC R11) for callers that don't supply one.
    public static func randomNodeId() -> Data {
        var d = Data(count: 16)
        let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        if rc != errSecSuccess {                       // defensive fallback; SystemRandom is CSPRNG-grade
            d = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        }
        return d
    }

    public func start() {
        log("STATE", "node-start myId=\(hex(myId)) (greater-nodeId dials)")
        peripheral = Peripheral(myId: myId, suppressAdvertising: suppressAdvertising,
            mintLinkId: { [weak self] in self?.mint() ?? 0 },
            onLink:     { [weak self] in self?.onUp($0) },
            onData:     { [weak self] in self?.onData($0, $1) },
            onClose:    { [weak self] in self?.onClose($0) },
            onPowerOff: { [weak self] in self?.closeAllLinks() })
        central = Central(myId: myId,
            mintLinkId: { [weak self] in self?.mint() ?? 0 },
            onLink:     { [weak self] in self?.onUp($0) },
            onData:     { [weak self] in self?.onData($0, $1) },
            onClose:    { [weak self] in self?.onClose($0) },
            onPowerOff: { [weak self] in self?.closeAllLinks() },
            haveLinkTo:       { [weak self] in self?.linksByPeerId[$0] != nil },
            haveLinkToPrefix: { [weak self] pre in self?.linksByPeerId.keys.contains { $0.prefix(6) == pre } ?? false })

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.printStatus() }
        bleRunLoop.add(t, forMode: .common)
        status = t

        #if os(iOS)
        // The BLE bearer owns its own background-wake: an iBeacon region monitor that relaunches a
        // force-quit app and pokes the Central back into scanning (BACKGROUND.md Layer C). Routed to
        // the same wake() the AppDelegate calls, so there is one wake path regardless of trigger.
        let bw = BeaconWake { [weak self] reason in self?.wake(reason) }
        bw.start()
        beaconWake = bw
        #endif
    }

    public func stop() {
        status?.invalidate(); status = nil
        #if os(iOS)
        beaconWake?.stop(); beaconWake = nil
        #endif
        closeAllLinks()
        central?.stop(); central = nil
        peripheral?.stop(); peripheral = nil
    }

    public func send(_ bytes: Data, on link: LinkId) {
        bleRunLoop.perform { [weak self] in
            guard let self, let l = self.linksByLinkId[link] else { return }    // no-op if link closed/unknown
            l.sendData(bytes)
        }
    }

    private func mint() -> LinkId { let id = nextLinkId; nextLinkId += 1; return id }

    private func printStatus() {
        if linksByPeerId.isEmpty {
            log("STATUS", "links=0")
            return
        }
        let detail = linksByPeerId.values
            .map { "peer=\($0.peerShort)/rx=\($0.rx)/tx=\($0.tx)/rtt=\($0.rttMs)ms/\($0.isDialer ? "dialer" : "acceptor")" }
            .joined(separator: " ")
        log("STATUS", "links=\(linksByPeerId.count) \(detail)")
    }

    private func onUp(_ link: Link) {               // HELLO completed: surface to sink, then dedup
        guard let peer = link.peerId else { return }
        linksByLinkId[link.linkId] = link           // register for send routing + linkDown pairing
        // Surface BEFORE dedup (matches the clean-room "LINK UP" timing: both legs of a duplicate pair
        // come up, then dedup closes the loser -> the consumer sees that loser's linkDown).
        sink?.linkUp(link.linkId, role: link.isDialer ? .dialer : .acceptor, peerId: peer)

        guard let existing = linksByPeerId[peer], existing !== link else {      // SPEC §2.3 dedup
            linksByPeerId[peer] = link
            return
        }
        let keepDialed = gt(myId, peer)             // keep MY dialed channel iff I'm the greater id
        let keep = [existing, link].first { $0.isDialer == keepDialed } ?? link
        let drop = (keep === link) ? existing : link
        linksByPeerId[peer] = keep                  // SPEC R3: set survivor BEFORE closing the dropped channel
        drop.close("dedup")
        log("DEDUP", "kept isDialer=\(keep.isDialer) peer=\(shortHex(peer))")
    }

    private func onData(_ link: Link, _ bytes: Data) {
        sink?.linkBytes(link.linkId, bytes)         // one DATA frame -> consumer
    }

    private func onClose(_ link: Link) {            // SPEC R3: identity-checked removal
        let wasUp = linksByLinkId.removeValue(forKey: link.linkId) != nil       // true iff linkUp had fired
        if let peer = link.peerId, linksByPeerId[peer] === link { linksByPeerId.removeValue(forKey: peer) }
        if wasUp { sink?.linkDown(link.linkId) }    // pair every linkDown with a prior linkUp
    }

    private func closeAllLinks() {                  // SPEC R11: drop all local links on power-off / stop
        for l in linksByPeerId.values { l.close("power-off") }
    }

    /// Called from the iOS AppDelegate on a CoreLocation region wake.
    public func wake(_ reason: String) { central?.wake(reason) }
}

// MARK: - misc ----------------------------------------------------------------------------------

func stateName(_ s: CBManagerState) -> String {
    switch s {
    case .poweredOn: return "poweredOn"
    case .poweredOff: return "poweredOff"
    case .resetting: return "resetting"
    case .unauthorized: return "unauthorized"
    case .unsupported: return "unsupported"
    case .unknown: return "unknown"
    @unknown default: return "?"
    }
}
