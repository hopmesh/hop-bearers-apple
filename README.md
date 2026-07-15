<p align="center">
  <img alt="Hop" src="https://hopme.sh/hop-mark.svg" width="200">
</p>

<h1 align="center">Hop Bearers for Apple</h1>

<p align="center">
  <b>The radios Hop rides on iOS and macOS: BLE, LAN, and cloud relay, as independent Swift packages.</b><br>
  Each bearer moves opaque bytes between two peers and conforms to one small contract, so a node plugs in only the transports it wants.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-F05138" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/platforms-iOS%2016%20%C2%B7%20macOS%2013-1f6feb" alt="iOS 16 · macOS 13">
  <img src="https://img.shields.io/badge/license-Apache--2.0-3ddc84" alt="license Apache-2.0">
</p>

---

Hop is a **delay-tolerant, end-to-end-encrypted mesh**: messages hop device to device over BLE, Wi-Fi,
and the internet until they reach the person or service you meant. Held, never dropped.

**Hop Bearers for Apple is the transport layer.** Three independent SwiftPM libraries (BLE, LAN, cloud
relay) each discover peers, form links, and shuttle application bytes, and each implements the same
tiny `Bearer` / `LinkSink` contract. The bearer owns the radio and its own dedup; the core never sees a
socket, and you pull in only the pipes you need.

## What's in the box

| Product          | Transport   | How it works                                                        |
| ---------------- | ----------- | ------------------------------------------------------------------- |
| `HopBearerBle`   | BLE         | GATT carries the PSM handshake, L2CAP carries data, iBeacon wakes a killed app |
| `HopBearerLan`   | Wi-Fi / LAN | mDNS `_hoplan._tcp` discovery over TCP                              |
| `HopBearerRelay` | Internet    | one outbound WebSocket to a relay (`URLSession`, no inbound port)   |

## Install

Add the package with Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/hopmesh/hop-bearers-apple.git", branch: "main"),
]
```

Then depend on the transports a target needs (each is its own product):

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "HopBearerBle",   package: "hop-bearers-apple"),
    .product(name: "HopBearerLan",   package: "hop-bearers-apple"),
    .product(name: "HopBearerRelay", package: "hop-bearers-apple"),
])
```

Each bearer depends only on the Hop SDK's `HopContract` (pure Swift, no `libhop`), so adding a bearer
never double-links the Rust core.

## Usage

Register the bearers you want with a `BearerManager` (one `LinkId` space across every radio) and give
it a sink. That's the whole seam:

```swift
import HopContract      // the Bearer / LinkSink contract, shipped with the Hop SDK
import HopBearerBle
import HopBearerLan
import HopBearerRelay

let myId = BleBearer.randomNodeId()          // 16 random bytes, stable for the process

let mesh = BearerManager()
mesh.register(BleBearer(myId: myId))         // GATT PSM handshake, L2CAP data, iBeacon wake
mesh.register(LanBearer(myId: myId))         // mDNS _hoplan._tcp + TCP
mesh.register(RelayBearer(relayURL: "wss://relay.hopme.sh/"))

mesh.sink = myConsumer                        // gets linkUp / linkBytes / linkDown
mesh.start()

// later, send opaque bytes on a live link; the core owns every byte of crypto
mesh.send(packet, on: linkId)
```

In a real app the sink is a Hop node: `HopRuntime` (in the Hop SDK) wires a `BearerManager` to a
`hop-core` node so every link drives the node and the node's outbound packets route back to the owning
bearer. If you're building your own client, conform to the contract directly.

## The contract

A bearer names nothing about BLE, Wi-Fi, or sockets. It reports three things and accepts `send`:

```swift
public protocol LinkSink: AnyObject {
    func linkUp(_ link: LinkId, role: HopRole, peerId: Data)
    func linkBytes(_ link: LinkId, _ bytes: Data)
    func linkDown(_ link: LinkId)
}

public protocol Bearer: AnyObject {
    var sink: LinkSink? { get set }
    var transportName: String { get }   // short UI tag: "BT" / "LAN" / "Relay"
    func start()
    func stop()
    func send(_ bytes: Data, on link: LinkId)
}
```

The Noise XX handshake that authenticates both ends lives inside the node, not the bearer, so a bearer
carries ciphertext it can't read.

## Status

Prototype. The pure link, dedup, and handshake logic (dial tiebreaker, keep-rule, deframing, backoff,
the 429 Retry-After parse) is extracted into headless cores and unit-tested under an 80% floor. The
radio glue that CI can't run (CoreBluetooth, the L2CAP runloop, the CoreLocation background wake) is
excluded from the coverage denominator and exercised on real hardware instead. BLE reliability follows
the Ditto design: GATT only for the PSM handshake, data always on L2CAP.

## The Hop family

Hop is one protocol with many faces. The endpoint SDKs, same surface in your language:
[node](https://github.com/hopmesh/hop-sdk-node) ·
[python](https://github.com/hopmesh/hop-sdk-python) ·
[go](https://github.com/hopmesh/hop-sdk-go) ·
[ruby](https://github.com/hopmesh/hop-sdk-ruby) ·
[crystal](https://github.com/hopmesh/hop-sdk-crystal) ·
[elixir](https://github.com/hopmesh/hop-sdk-elixir) ·
[apple](https://github.com/hopmesh/hop-sdk-apple) ·
[android](https://github.com/hopmesh/hop-sdk-android).
The protocol core is [hop-core](https://github.com/hopmesh/hop-core) / [libhop](https://github.com/hopmesh/libhop).

## License

[Apache-2.0](./LICENSE.md), use it freely. Only the protocol core (`hop-core`) is FSL-1.1-ALv2,
source-available and converting to Apache-2.0 after two years.
