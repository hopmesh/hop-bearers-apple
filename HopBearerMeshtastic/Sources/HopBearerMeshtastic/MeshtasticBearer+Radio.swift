// CoreBluetoothMeshtasticRadio, the REAL Meshtastic device connection: a CoreBluetooth central that scans
// for a Meshtastic radio, connects over its GATT service, and moves ToRadio/FromRadio protobuf frames.
// This is the radio glue for MeshtasticBearer, split into its own file so the coverage gate can EXCLUDE it
// from the denominator (see the apple CI job): CoreBluetooth has no headless support, so none of this can
// run under `swift test`. The bearer's state machine and all Meshtastic protocol parsing live in the
// testable files (MeshtasticBearer.swift / MeshtasticWire.swift); this file is exercised only on device.
//
// Meshtastic BLE protocol (the stable "BLE API"):
//   Service          6ba1b218-15a8-461f-9fa8-5dcae273eafd
//   ToRadio  (write) f75c76d2-129e-4dad-a1dd-7866124401e7   the phone writes one ToRadio protobuf per write
//   FromRadio (read) 2c55e69e-4993-11ed-b878-0242ac120002   each READ returns one FromRadio protobuf, or
//                                                            empty once the radio's queue is drained
//   FromNum (notify) ed9da18c-a800-4f66-a670-aa7547e34453   notifies when new FromRadio frames are queued
//
// Flow: connect, discover the three characteristics, subscribe to FromNum, then WRITE want_config and
// DRAIN FromRadio (read until empty) on every FromNum notification.

import Foundation
import CoreBluetooth

final class CoreBluetoothMeshtasticRadio: NSObject, MeshtasticRadio {
    var onConnect: (() -> Void)?
    var onDisconnect: (() -> Void)?
    var onFromRadio: (([UInt8]) -> Void)?

    static let serviceUUID = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioUUID = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNumUUID = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    private let cbQueue = DispatchQueue(label: "hop.mesh.cb")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var running = false

    func start() {
        cbQueue.async {
            self.running = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.cbQueue)
            } else {
                self.scanIfPowered()
            }
        }
    }

    func stop() {
        cbQueue.async {
            self.running = false
            self.central?.stopScan()
            if let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
            self.peripheral = nil; self.toRadio = nil; self.fromRadio = nil
        }
    }

    func send(toRadio bytes: [UInt8]) {
        cbQueue.async {
            guard let p = self.peripheral, let ch = self.toRadio else { return }
            p.writeValue(Data(bytes), for: ch, type: .withResponse)
        }
    }

    private func scanIfPowered() {
        guard running, let central, central.state == .poweredOn, peripheral == nil else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    private func drainFromRadio() {
        guard let p = peripheral, let ch = fromRadio else { return }
        p.readValue(for: ch)   // each read yields one FromRadio; we re-read on every value until empty
    }
}

extension CoreBluetoothMeshtasticRadio: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) { scanIfPowered() }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil; self.toRadio = nil; self.fromRadio = nil
        onDisconnect?()
        scanIfPowered()   // reconnect: scan again while we are still running
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        self.peripheral = nil
        scanIfPowered()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics(
            [Self.toRadioUUID, Self.fromRadioUUID, Self.fromNumUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case Self.toRadioUUID: toRadio = ch
            case Self.fromRadioUUID: fromRadio = ch
            case Self.fromNumUUID: peripheral.setNotifyValue(true, for: ch)
            default: break
            }
        }
        guard toRadio != nil, fromRadio != nil else { return }
        onConnect?()          // the bearer now writes want_config and starts talking
        drainFromRadio()      // pull whatever is already queued
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == Self.fromNumUUID {
            drainFromRadio()   // radio signalled new frames are queued
            return
        }
        guard characteristic.uuid == Self.fromRadioUUID else { return }
        guard let value = characteristic.value, !value.isEmpty else { return }  // empty read = drained
        onFromRadio?([UInt8](value))
        drainFromRadio()       // keep reading until an empty value drains the queue
    }
}
