import Foundation
import XCTest
@testable import HopBearerMeshtastic

/// Byte-level tests for the minimal Meshtastic protobuf codec and the Hop link-frame grammar. These pin
/// the exact wire encoding the bearer produces and the exact decode of what a radio sends back.
final class MeshProtoTests: XCTestCase {

    func testVarintRoundTrip() {
        for v: UInt64 in [0, 1, 127, 128, 255, 256, 300, 16_383, 16_384, 1 << 32, UInt64.max] {
            var w = ProtoWriter(); w.varintField(1, v)
            var r = ProtoReader(w.bytes)
            guard let (field, wire) = r.readTag() else { return XCTFail("no tag") }
            XCTAssertEqual(field, 1); XCTAssertEqual(wire, 0)
            XCTAssertEqual(r.readVarint(), v)
        }
    }

    func testFixed32LittleEndian() {
        var w = ProtoWriter(); w.fixed32Field(6, 0x0102_0304)
        // tag for field 6 wire 5 = (6<<3)|5 = 53 = 0x35, then LE bytes 04 03 02 01
        XCTAssertEqual(w.bytes, [0x35, 0x04, 0x03, 0x02, 0x01])
        var r = ProtoReader(w.bytes)
        _ = r.readTag()
        XCTAssertEqual(r.readFixed32(), 0x0102_0304)
    }

    func testDataEncodeDecodeOnHopPort() {
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        let data = MeshtasticProto.encodeData(payload: payload)
        XCTAssertEqual(MeshtasticProto.decodeHopData(data), payload)
    }

    func testDataOnWrongPortIsIgnored() {
        // Hand-build a Data on portnum 1 (TEXT_MESSAGE_APP), which the bearer must not surface.
        var w = ProtoWriter(); w.varintField(1, 1); w.bytesField(2, [9, 9])
        XCTAssertNil(MeshtasticProto.decodeHopData(w.bytes))
    }

    func testDecodeFromRadioMyNodeNum() {
        var info = ProtoWriter(); info.varintField(1, 4242)
        var w = ProtoWriter(); w.bytesField(3, info.bytes)   // my_info
        XCTAssertEqual(MeshtasticProto.decodeFromRadio(w.bytes), .myNodeNum(4242))
    }

    func testDecodeFromRadioHopPacket() {
        var pkt = ProtoWriter()
        pkt.fixed32Field(1, 77)                                  // from
        pkt.bytesField(4, MeshtasticProto.encodeData(payload: [0xAA, 0xBB]))
        var w = ProtoWriter(); w.bytesField(2, pkt.bytes)       // packet
        XCTAssertEqual(MeshtasticProto.decodeFromRadio(w.bytes), .hopData(from: 77, payload: [0xAA, 0xBB]))
    }

    func testDecodeFromRadioSkipsUnknownFields() {
        // A FromRadio with config_complete_id (field 7, varint) only -> nothing the bearer acts on.
        var w = ProtoWriter(); w.varintField(7, 1234)
        XCTAssertNil(MeshtasticProto.decodeFromRadio(w.bytes))
    }

    func testDecodeToRadioPacketRoundTrip() {
        let frame = MeshtasticProto.encodeToRadioPacket(
            from: 10, to: 20, id: 999, hopLimit: 3, fragment: [7, 8, 9])
        // ToRadio.packet is field 1; unwrap it and read from/to/decoded.
        var r = ProtoReader(frame)
        guard let (field, wire) = r.readTag(), field == 1, wire == 2, let pkt = r.readBytes() else {
            return XCTFail("not a packet ToRadio")
        }
        let inbound = MeshtasticProto.decodeMeshPacket(pkt)
        XCTAssertEqual(inbound, .hopData(from: 10, payload: [7, 8, 9]))
    }

    func testWantConfigEncodes() {
        let bytes = MeshtasticProto.encodeWantConfig(0xABCD)
        var r = ProtoReader(bytes)
        guard let (field, wire) = r.readTag() else { return XCTFail("no tag") }
        XCTAssertEqual(field, 3); XCTAssertEqual(wire, 0)
        XCTAssertEqual(r.readVarint(), 0xABCD)
    }

    func testTruncatedVarintRefused() {
        // A tag that promises a varint but the buffer ends: reader returns nil, decoder returns nil.
        XCTAssertNil(MeshtasticProto.decodeFromRadio([0x08]))   // field 1 varint, no body
    }

    func testTruncatedLengthDelimitedRefused() {
        // field 2 length-delimited claiming 5 bytes but only 1 present.
        XCTAssertNil(MeshtasticProto.decodeFromRadio([0x12, 0x05, 0x00]))
    }

    func testFrameGrammar() {
        let id = Data((0..<16).map { UInt8($0) })
        let hello = MeshFrame.hello(myId: id, isGreater: true)
        XCTAssertEqual(hello.first, M_HELLO)
        XCTAssertEqual(MeshFrame.helloPeerId(hello), id)
        XCTAssertEqual(hello[17], 1)   // role byte: greater

        let ping = MeshFrame.ping(seq: 5, nowMs: 1000)
        XCTAssertEqual(ping.first, M_PING)
        XCTAssertEqual(MeshFrame.u64dec(Array(ping[1...]), 0), 5)

        XCTAssertEqual(MeshFrame.pong(echo: [1, 2, 3]), [M_PONG, 1, 2, 3])
        XCTAssertEqual(MeshFrame.data([9, 9]), [M_DATA, 9, 9])
        XCTAssertNil(MeshFrame.helloPeerId([M_HELLO, 1, 2]))   // too short
    }
}
