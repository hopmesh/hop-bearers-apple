// BleBearer+Radio, the CoreBluetooth half of the BLE bearer: the `Link` (CBL2CAPChannel + stream I/O),
// the `Central`/`Peripheral` delegate SHELLS, and `BleBearer.start()/stop()/wake()`. Everything here
// names a CoreBluetooth (or CoreLocation) type, so NONE of it runs under `swift test`: CoreBluetooth has
// no iOS-Simulator/headless support, and CBPeripheral/CBService/CBCharacteristic/CBL2CAPChannel/CBATTRequest
// have no public initializers, so the live radio cannot be exercised in a unit test. This file is therefore
// EXCLUDED from the CI line-coverage denominator (see tools/apple-cov-gate.sh + .github/workflows/ci.yml)
// and is instead covered by the on-device hopmac / testkit workflow, the same convention HopDriver uses
// for HopBearer+Radios.swift / HopLink.swift.
//
// The shells are DELIBERATELY thin: each CB delegate method translates its CoreBluetooth arguments into
// plain values, calls the matching CentralCore/PeripheralCore method, and executes the returned effects
// verbatim (in order). The DECISION logic those cores hold is unit-tested in CentralCoreTests /
// PeripheralCoreTests; the shell is a mechanical 1:1 CB translation, so the split is behavior-preserving.

import Foundation
import CoreBluetooth
import HopContract
#if os(iOS)
import CoreLocation   // CLBeaconRegion, the iBeacon EMISSION payload (iOS-only)
#endif

// MARK: - Fresh service scheme (SPEC §1.1) -------------------------------------------------------

let SERVICE_UUID  = CBUUID(string: "7ED70001-3C2A-4F19-9B8E-1A2B3C4D5E6F")   // advertised + GATT service
let ENDPOINT_CHAR = CBUUID(string: "7ED70002-3C2A-4F19-9B8E-1A2B3C4D5E6F")   // GATT READ -> [2B PSM BE][16B nodeId]
let MFG_COMPANY_ID: UInt16 = 0xFFFF                                          // "reserved for testing" company id

let RESTORE_ID_PERIPHERAL = "hoplab.ble.peripheral"
let RESTORE_ID_CENTRAL    = "hoplab.ble.central"

// MARK: - Link: one L2CAP channel, 4-byte BE framing, 1 Hz PING (keepalive), adaptive watchdog -----
// SPEC §4 framing, §3.3 HELLO, §5 keepalive/liveness. Conforms to DedupLink so the bearer's dedup +
// send routing + STATUS run against it without naming CoreBluetooth.

final class Link: NSObject, StreamDelegate, DedupLink {
    let linkId: LinkId                              // monotonic id minted by the bearer; the sink's key
    let isDialer: Bool
    let myId: Data
    private(set) var peerId: Data?                  // learned from HELLO; the dedup/tiebreak key
    private(set) var up = false
    // apple-12: set true by the bearer iff this exact leg was announced to the sink via linkUp. A
    // deduped loser is closed without ever being surfaced, so its onClose must NOT emit a linkDown.
    // Touched only from bearer code under BleBearer.mapLock, so no additional synchronization here.
    var wasSurfaced = false

    // CRITICAL: retain the CBL2CAPChannel for the link's whole life. inputStream/outputStream are
    // just views onto the channel's socket fd; if the channel deallocs, that fd is closed and the
    // streams immediately fail with POSIX EBADF (Bad file descriptor) right after openCompleted.
    // (Android's Link stores the BluetoothSocket for the same reason.)
    private let channel: CBL2CAPChannel
    private let input: InputStream
    private let output: OutputStream
    private var deframer = BleDeframer()   // the pure length-prefix parser (unit-tested separately)
    private var outBuf = [UInt8]()

    private var lastRxMs = nowMs()
    private let openedMs = nowMs()
    private var becameUpMs: UInt64?
    private var lastTickMs = nowMs()                // apple-02(b): detect suspension via tick-gap
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
    // CRITICAL: a Link is only inserted into BleBearer.linksByPeerId in onUp, i.e. AFTER the peer's
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

        log("STATE", "channel-open isDialer=\(isDialer), scheduling streams")
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
        let now = nowMs()
        let tickGapS = Double(now - lastTickMs) / 1000
        lastTickMs = now
        switch livenessVerdict(up: up, openedGapS: Double(now - openedMs) / 1000,
                               rxGapS: Double(now - lastRxMs) / 1000,
                               tickGapS: tickGapS, deadLimitS: deadLimitS()) {
        case .keep:
            break
        case .reapNoHello:
            close("no-HELLO reap")
        case .reapDead:
            close("liveness DEAD")
        case .suspendGrace:
            // apple-02(b): we were suspended across this interval, not idle. Don't count the sleep
            // against the peer: reset the RX clock and probe once. Only a subsequent tick with real
            // silence (peer actually gone) will reap.
            log("STATE", "liveness suspend-grace (tickGap=\(String(format: "%.1f", tickGapS))s) peer=\(peerShort), probing instead of reaping")
            lastRxMs = now
            sendPing()
        }
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
        selfRetain = nil           // release self, safe to dealloc now (see selfRetain decl)
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
        var got = [UInt8]()
        while input.hasBytesAvailable {
            let n = input.read(&tmp, maxLength: tmp.count)
            if n > 0 { got.append(contentsOf: tmp[0..<n]) } else { break }
        }
        let gap = Double(nowMs() - lastRxMs)
        ewmaGapMs = 0.8 * ewmaGapMs + 0.2 * gap
        lastRxMs = nowMs()
        deframe(got)
    }

    private func deframe(_ bytes: [UInt8]) {
        var overLimit = false
        let frames = deframer.feed(bytes, overLimit: &overLimit)
        for f in frames { handle(f) }
        if overLimit { close("bad len") }
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

// MARK: - ACCEPTOR (peripheral): CB delegate shell over PeripheralCore ----------------------------
// SPEC §3.1. The publish/advertise/self-heal DECISIONS live in PeripheralCore; this shell owns the
// CBPeripheralManager, the F-12 self-heal timer, and the iOS advert-cycle timer, and executes effects.

/// F-12: how often the peripheral re-checks that it is still discoverable (L2CAP published +
/// advertising) and re-arms if not. ble-lab SPEC §7.1 requires this periodic self-heal.
private let PERIPHERAL_HEAL_S: Double = 30.0

final class Peripheral: NSObject, CBPeripheralManagerDelegate {
    private var pm: CBPeripheralManager!
    private let core: PeripheralCore
    private var healScheduled = false
    private let myId: Data
    private let mintLinkId: () -> LinkId
    private let onLink: (Link) -> Void
    private let onData: (Link, Data) -> Void
    private let onClose: (Link) -> Void
    private let onPowerOff: () -> Void
    #if os(iOS)
    private var advTimer: DispatchSourceTimer?
    #endif

    init(myId: Data, suppressAdvertising: Bool, mintLinkId: @escaping () -> LinkId,
         onLink: @escaping (Link) -> Void, onData: @escaping (Link, Data) -> Void,
         onClose: @escaping (Link) -> Void, onPowerOff: @escaping () -> Void) {
        self.core = PeripheralCore(myId: myId, suppressAdvertising: suppressAdvertising)
        self.myId = myId; self.mintLinkId = mintLinkId
        self.onLink = onLink; self.onData = onData; self.onClose = onClose; self.onPowerOff = onPowerOff
        super.init()
        pm = CBPeripheralManager(delegate: self, queue: bleQueue,
                                 options: [CBPeripheralManagerOptionRestoreIdentifierKey: RESTORE_ID_PERIPHERAL])
        scheduleSelfHeal()   // F-12: keep the advertiser/L2CAP re-armed
    }

    func stop() {
        let wasPublished = core.markStopped()
        guard let pm = pm else { return }
        #if os(iOS)
        advTimer?.cancel(); advTimer = nil
        #endif
        pm.stopAdvertising()
        if wasPublished { pm.unpublishL2CAPChannel(core.psm) }
        pm.removeAllServices()
    }

    // F-12: periodic self-heal (ble-lab SPEC §7.1). The DECISION (publish vs advertise vs nothing) is
    // PeripheralCore.selfHeal; this loop just supplies the live radio state and re-arms itself.
    private func scheduleSelfHeal() {
        guard !healScheduled else { return }
        healScheduled = true
        bleQueue.asyncAfter(deadline: .now() + PERIPHERAL_HEAL_S) { [weak self] in
            guard let self else { return }
            self.healScheduled = false
            if let pm = self.pm {
                self.run(self.core.selfHeal(isPoweredOn: pm.state == .poweredOn, isAdvertising: pm.isAdvertising), pm)
            }
            if !self.core.stopped { self.scheduleSelfHeal() }
        }
    }

    // Execute a PeripheralCore effect list against the live CBPeripheralManager, in order.
    private func run(_ effects: [PeripheralEffect], _ pm: CBPeripheralManager) {
        for e in effects {
            switch e {
            case .powerOff:
                onPowerOff()                                                    // SPEC R11
            case .addServiceAndPublish:
                let ch = CBMutableCharacteristic(type: ENDPOINT_CHAR, properties: .read, value: nil, permissions: .readable)
                let svc = CBMutableService(type: SERVICE_UUID, primary: true)
                svc.characteristics = [ch]
                pm.add(svc)
                log("STATE", "peripheral gatt-service-added")
                pm.publishL2CAPChannel(withEncryption: false)                   // INSECURE CoC (SPEC §1.1)
            case .publishL2CAP:
                log("STATE", "peripheral self-heal: republishing L2CAP")
                pm.publishL2CAPChannel(withEncryption: false)
            case .startAdvertising:
                log("STATE", "peripheral self-heal: restarting advertising")
                pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])
            case .advertisingSuppressed:
                log("STATE", "peripheral advertising-SUPPRESSED (central-only), publish-only, no advertising")
            case .startAdvertisingAfterPublish:
                #if os(iOS)
                // iOS: alternate service-UUID advert (L2CAP discovery) with an iBeacon advert (bg wake).
                startAdvertisingCycle(pm)
                #else
                pm.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [SERVICE_UUID]])  // UUID only (SPEC §1.3)
                log("STATE", "peripheral advertising-started service=\(SERVICE_UUID.uuidString)")
                #endif
            }
        }
    }

    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        log("STATE", "peripheral state=\(stateName(p.state))")
        run(core.stateChanged(isPoweredOn: p.state == .poweredOn, isPoweredOff: p.state == .poweredOff), p)
    }

    func peripheralManager(_ p: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        if let error {
            log("STATE", "peripheral l2cap-publish-FAILED \(error.localizedDescription), self-heal will retry")
            run(core.publishResult(psm: 0, failed: true), p)
            return
        }
        log("STATE", "peripheral l2cap-published psm=\(PSM)")
        run(core.publishResult(psm: PSM, failed: false), p)
    }

    #if os(iOS)
    /// Advertise on a ~7s cycle: ~5s service-UUID (peers discover us + read the PSM to open L2CAP),
    /// ~2s iBeacon (nearby dormant/force-quit apps monitoring BEACON_UUID get woken). The cadence
    /// DECISION is PeripheralCore.advCycleStep; this timer just drives it at 1 Hz and applies the result.
    private func startAdvertisingCycle(_ p: CBPeripheralManager) {
        applyAdvertising(p, beacon: false)
        let t = DispatchSource.makeTimerSource(queue: bleQueue)
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self, weak p] in
            guard let self, let p else { return }
            let step = self.core.advCycleStep()
            if step.apply { self.applyAdvertising(p, beacon: step.beacon) }
        }
        advTimer?.cancel()
        advTimer = t
        t.resume()
    }

    /// Emit either the service-UUID advert (peers discover us + read the PSM) or the iBeacon advert (wake).
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
        if let error { log("STATE", "peripheral advertising-FAILED \(error.localizedDescription), self-heal will retry") }
    }

    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        req.value = core.readResponse()                                         // [2B PSM BE][16B nodeId]
        p.respond(to: req, withResult: .success)
        log("STATE", "peripheral read-request -> psm=\(core.psm) id=\(shortHex(myId))")
    }

    func peripheralManager(_ p: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if let error { log("STATE", "peripheral inbound-l2cap-FAILED \(error.localizedDescription)"); return }
        guard let channel else { return }
        log("STATE", "peripheral inbound-l2cap-open (acceptor)")
        // SPEC §8.1 iOS adaptation: hand the channel to the I/O thread so Stream.schedule(in: bleRunLoop)
        // + Timer additions run on the thread that owns bleRunLoop. No-op when bleRunLoop == .main.
        let myId = self.myId, mintLinkId = self.mintLinkId, onLink = self.onLink, onData = self.onData, onClose = self.onClose
        bleRunLoop.perform {
            _ = Link(channel: channel, linkId: mintLinkId(), isDialer: false, myId: myId,
                     onUp: onLink, onData: onData, onClose: onClose)
        }
    }

    func peripheralManager(_ p: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // SPEC R10: after a system relaunch CoreBluetooth restores our services + published channel, then
        // calls didUpdateState(.poweredOn) which re-adds + republishes; the F-12 loop guarantees advertising
        // restarts. Reset `published` so the heal loop re-publishes if the restored channel is not live.
        log("STATE", "peripheral willRestoreState, re-arm on poweredOn + self-heal")
        core.willRestore()
    }
}

// MARK: - DIALER (central): CB delegate shell over CentralCore ------------------------------------
// SPEC §3.2. The dial gating / backoff / retained DECISIONS live in CentralCore; this shell owns the
// CBCentralManager, the CBPeripheral handles (`cbPeers`), and the dial-timeout work items, and executes
// the returned effects. `cbPeers` is kept in lockstep with `core.retained` by `reconcile` after each call.

final class Central: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var cm: CBCentralManager!
    private let core: CentralCore
    private let myId: Data

    private var cbPeers = [UUID: CBPeripheral]()        // strong ref while dialing/linked (SPEC §3.2.3)
    private var dialTimers = [UUID: DispatchWorkItem]() // SPEC R6: 12 s dial-timeout per peer

    private let mintLinkId: () -> LinkId
    private let onLink: (Link) -> Void
    private let onData: (Link, Data) -> Void
    private let onClose: (Link) -> Void
    private let onPowerOff: () -> Void

    init(myId: Data, mintLinkId: @escaping () -> LinkId,
         onLink: @escaping (Link) -> Void, onData: @escaping (Link, Data) -> Void,
         onClose: @escaping (Link) -> Void, onPowerOff: @escaping () -> Void,
         haveLinkTo: @escaping (Data) -> Bool, haveLinkToPrefix: @escaping (Data) -> Bool) {
        self.core = CentralCore(myId: myId, haveLinkTo: haveLinkTo, haveLinkToPrefix: haveLinkToPrefix)
        self.myId = myId; self.mintLinkId = mintLinkId
        self.onLink = onLink; self.onData = onData; self.onClose = onClose; self.onPowerOff = onPowerOff
        super.init()
        cm = CBCentralManager(delegate: self, queue: bleQueue,
                              options: [CBCentralManagerOptionRestoreIdentifierKey: RESTORE_ID_CENTRAL])
    }

    func stop() {
        cm?.stopScan()
        for peer in cbPeers.values { cm?.cancelPeripheralConnection(peer) }
        dialTimers.values.forEach { $0.cancel() }
        dialTimers.removeAll(); cbPeers.removeAll()
        core.stopReset()
    }

    // Resolve the CBPeripheral for an id: prefer the just-delivered callback peer, else the retained handle.
    private func handle(_ id: UUID, current p: CBPeripheral?) -> CBPeripheral? {
        if let p, p.identifier == id { return p }
        return cbPeers[id]
    }

    // Execute a CentralCore effect list against CoreBluetooth (in order), then reconcile `cbPeers` to the
    // core's retained set (add the current peer if newly retained; drop any peer no longer retained).
    private func execute(_ effects: [CentralEffect], current p: CBPeripheral?) {
        for e in effects { perform(e, current: p) }
        if let p, core.retained.contains(p.identifier) { cbPeers[p.identifier] = p }
        for id in Array(cbPeers.keys) where !core.retained.contains(id) { cbPeers[id] = nil }
    }

    private func perform(_ e: CentralEffect, current p: CBPeripheral?) {
        switch e {
        case .scan:
            cm.scanForPeripherals(withServices: [SERVICE_UUID],                  // filter REQUIRED for bg scan
                                  options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("STATE", "central scan-started service=\(SERVICE_UUID.uuidString)")
        case .powerOff:
            onPowerOff()                                                         // SPEC R11
        case .connect(let id):
            guard let peer = handle(id, current: p) else { return }
            peer.delegate = self
            cm.connect(peer, options: nil)
            log("STATE", "DIALING id=\(id.uuidString.prefix(8))")
        case .cancelConnection(let id):
            guard let peer = handle(id, current: p) else { return }
            cm.cancelPeripheralConnection(peer)
        case .discoverServices(let id):
            guard let peer = handle(id, current: p) else { return }
            peer.discoverServices(nil)                                          // SPEC: nil, not [SERVICE_UUID]
        case .openL2CAP(let id, let psm):
            guard let peer = handle(id, current: p) else { return }
            log("STATE", "openL2CAPChannel psm=\(psm) id=\(id.uuidString.prefix(8))")
            peer.openL2CAPChannel(CBL2CAPPSM(psm))
        case .armDialTimeout(let id):
            dialTimers[id]?.cancel()                                            // defensive; dial() guards no dup
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.execute(self.core.dialTimeoutFired(id), current: nil)     // fired -> abort + reconnect
            }
            dialTimers[id] = work
            bleQueue.asyncAfter(deadline: .now() + DIAL_TIMEOUT_S, execute: work)
        case .cancelDialTimeout(let id):
            dialTimers[id]?.cancel(); dialTimers[id] = nil                      // clearDialTimer
        case .armWaitTimeout(let id, let advPrefix):
            let peer = p   // capture the deferred peer's handle (it is NOT retained until we dial it)
            bleQueue.asyncAfter(deadline: .now() + WAIT_BASE_S + Double.random(in: 0...1)) { [weak self] in
                guard let self else { return }
                log("STATE", "wait-timeout fired -> id=\(id.uuidString.prefix(8))")
                self.execute(self.core.waitTimeoutFired(id, advPrefix: advPrefix), current: peer)
            }
        }
    }

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("STATE", "central state=\(stateName(c.state))")
        execute(core.stateChanged(isPoweredOn: c.state == .poweredOn, isPoweredOff: c.state == .poweredOff), current: nil)
    }

    /// Background-wake hook (CoreLocation region enter, or app relaunch). Idempotent. Runs on bleQueue so
    /// all Central state stays single-homed (apple-01).
    func wake(_ reason: String) {
        bleQueue.async { [weak self] in
            guard let self, let cm = self.cm else { return }
            log("STATE", "WAKE(\(reason)) state=\(stateName(cm.state)) scanning=\(cm.isScanning)")
            guard cm.state == .poweredOn else { return }
            self.execute(self.core.wakeRearmScan(isScanning: cm.isScanning), current: nil)
            for peer in cm.retrieveConnectedPeripherals(withServices: [SERVICE_UUID]) {
                self.execute(self.core.adopt(peer.identifier), current: peer)
            }
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData d: [String: Any], rssi: NSNumber) {
        var advPrefix: Data? = nil
        if let mfg = d[CBAdvertisementDataManufacturerDataKey] as? Data, mfg.count >= 8,
           mfg[0] == 0xFF, mfg[1] == 0xFF { advPrefix = mfg.subdata(in: 2..<8) } // 6-byte nodeId prefix
        log("STATE", "discovered id=\(p.identifier.uuidString.prefix(8)) prefix=\(advPrefix.map(hex) ?? "none") rssi=\(rssi) bg=\(bleAppInBackground)")
        execute(core.discovered(p.identifier, advPrefix: advPrefix), current: p)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("STATE", "connected id=\(p.identifier.uuidString.prefix(8)), discoverServices(nil)")
        execute(core.connected(p.identifier), current: p)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("STATE", "didFailToConnect id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "")")
        execute(core.disconnected(p.identifier), current: p)
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("STATE", "didDisconnect id=\(p.identifier.uuidString.prefix(8)) \(error?.localizedDescription ?? "")")
        execute(core.disconnected(p.identifier), current: p)
    }

    func peripheral(_ p: CBPeripheral, didModifyServices invalidated: [CBService]) {
        log("STATE", "didModifyServices id=\(p.identifier.uuidString.prefix(8)), re-discover (defeat stale cache)")
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
        let psm = UInt16(v[0]) << 8 | UInt16(v[1])
        log("STATE", "read psm=\(psm) peer=\(shortHex(peerId)) id=\(p.identifier.uuidString.prefix(8))")
        execute(core.readEndpointValue(p.identifier, psm: psm, peerId: peerId), current: p)
    }

    func peripheral(_ p: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        if error != nil {
            log("STATE", "l2cap-open-error -> re-read id=\(p.identifier.uuidString.prefix(8)) \(error!.localizedDescription)")
            execute(core.channelOpenFailed(p.identifier), current: p)           // stale PSM -> re-read (SPEC §7.4)
            return
        }
        guard let channel else { return }
        log("STATE", "l2cap-open success (dialer) id=\(p.identifier.uuidString.prefix(8))")
        execute(core.channelOpened(p.identifier), current: p)                   // clear dial timeout + backoff
        // SPEC §8.1 iOS adaptation: construct Link on the I/O thread that owns bleRunLoop.
        let id = p.identifier
        let myId = self.myId, mintLinkId = self.mintLinkId, onLink = self.onLink, onData = self.onData
        let onCloseBearer = self.onClose
        let onCloseChain: (Link) -> Void = { [weak self] l in
            if let self { self.execute(self.core.dialerLinkClosed(id, stableUp: l.stableUp), current: nil) }
            onCloseBearer(l)
        }
        bleRunLoop.perform {
            _ = Link(channel: channel, linkId: mintLinkId(), isDialer: true, myId: myId,
                     onUp: onLink, onData: onData, onClose: onCloseChain)
        }
    }

    func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        log("STATE", "central willRestoreState peripherals=\(restored.count)")
        for peer in restored {
            peer.delegate = self              // the system does NOT keep our delegate wiring
            execute(core.restore(peer.identifier, isConnected: peer.state == .connected), current: peer)
        }
        // scan re-arms in centralManagerDidUpdateState(.poweredOn), which fires next.
    }
}

// MARK: - BleBearer radio wiring: start/stop/wake (construct + drive the CB planes) ---------------

extension BleBearer {
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
            haveLinkTo:       { [weak self] in self?.haveLinkTo($0) ?? false },
            haveLinkToPrefix: { [weak self] pre in self?.haveLinkToPrefix(pre) ?? false })

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
        bgAssertion.end("bearer-stop")   // apple-02(a): never strand the assertion
        #if os(iOS)
        beaconWake?.stop(); beaconWake = nil
        #endif
        closeAllLinks()
        central?.stop(); central = nil
        peripheral?.stop(); peripheral = nil
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
