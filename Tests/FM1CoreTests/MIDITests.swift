import XCTest
@testable import FM1Core

final class MIDIParserTests: XCTestCase {
    func testRunningStatusAndRealtimeInterleave() {
        var p = MIDIParser()
        // Note on, then running-status note on, with a clock byte jammed in the middle.
        let msgs = p.feed([0x90, 60, 100, 0xF8, 62, 0])
        XCTAssertEqual(msgs, [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .clock,
            .noteOn(channel: 0, note: 62, velocity: 0),
        ])
        XCTAssertTrue(msgs[2].isNoteOff)
    }

    func testSysexSplitAcrossPackets() {
        var p = MIDIParser()
        XCTAssertEqual(p.feed([0xF0, 0x7E, 0x00]), [])
        XCTAssertEqual(p.feed([0x06, 0xF8, 0x01, 0xF7]), [.clock, .sysex([0xF0, 0x7E, 0x00, 0x06, 0x01, 0xF7])])
    }

    func testPitchBendRoundTrip() {
        let m = MIDIMessage.pitchBend(channel: 3, value: 12345)
        var p = MIDIParser()
        XCTAssertEqual(p.feed(m.bytes), [m])
    }

    func testSystemCommonClearsRunningStatus() {
        var p = MIDIParser()
        XCTAssertEqual(p.feed([0xB0, 1, 64, 0xF3, 5, 7, 8]), [
            .controlChange(channel: 0, controller: 1, value: 64),
            .songSelect(5),
        ])
    }
}

final class UMPTests: XCTestCase {
    func testChannelVoiceRoundTrip() {
        let msgs: [MIDIMessage] = [
            .noteOn(channel: 9, note: 36, velocity: 127),
            .controlChange(channel: 0, controller: 74, value: 12),
            .pitchBend(channel: 1, value: 0),
            .clock, .start, .songPosition(300),
        ]
        var dec = UMPDecoder()
        let words = msgs.flatMap { UMPEncoder.words(for: $0) }
        XCTAssertEqual(dec.decode(words), msgs)
    }

    func testLongSysexRoundTrip() {
        let sx: [UInt8] = [0xF0] + (0..<20).map { UInt8($0) } + [0xF7]
        var dec = UMPDecoder()
        let words = UMPEncoder.words(for: .sysex(sx))
        XCTAssertEqual(words.count, 8) // 20 bytes -> 4 packets of 2 words
        XCTAssertEqual(dec.decode(words), [.sysex(sx)])
    }

    func testEmptySysex() {
        var dec = UMPDecoder()
        XCTAssertEqual(dec.decode(UMPEncoder.words(for: .sysex([0xF0, 0xF7]))), [.sysex([0xF0, 0xF7])])
    }

    func testMIDI2NoteOnDownconvert() {
        var dec = UMPDecoder()
        let w0: UInt32 = (0x4 << 28) | (0x90 << 16) | (60 << 8)
        let w1: UInt32 = 0xFFFF_0000
        XCTAssertEqual(dec.decode([w0, w1]), [.noteOn(channel: 0, note: 60, velocity: 127)])
    }
}

final class MIDIRouterTests: XCTestCase {
    let keys = EndpointID(.hardware, "KeyStep Pro")
    let moog = EndpointID(.hardware, "Subsequent 37")
    let koala = EndpointID(.virtualPort, "Koala")

    func testSplitKeyboard() {
        var low = MIDIFilter(); low.highestNote = 59
        var high = MIDIFilter(); high.lowestNote = 60
        let router = MIDIRouter(routes: [
            MIDIRoute(source: keys, destination: moog, filter: low),
            MIDIRoute(source: keys, destination: koala, filter: high),
        ])
        XCTAssertEqual(router.process(.noteOn(channel: 0, note: 40, velocity: 90), from: keys),
                       [RoutedMIDI(moog, .noteOn(channel: 0, note: 40, velocity: 90))])
        XCTAssertEqual(router.process(.noteOn(channel: 0, note: 72, velocity: 90), from: keys),
                       [RoutedMIDI(koala, .noteOn(channel: 0, note: 72, velocity: 90))])
    }

    func testTransposeChangeWhileHeldDoesNotHangNotes() {
        var t = MIDITransform(); t.transpose = 12; t.outputChannel = 2
        let route = MIDIRoute(source: keys, destination: moog, transform: t)
        let router = MIDIRouter(routes: [route])
        _ = router.process(.noteOn(channel: 0, note: 60, velocity: 100), from: keys)

        // User changes the transpose while the key is down.
        var edited = route
        edited.transform.transpose = -5
        _ = router.setRoutes([edited])

        let off = router.process(.noteOff(channel: 0, note: 60, velocity: 0), from: keys)
        XCTAssertEqual(off, [RoutedMIDI(moog, .noteOff(channel: 2, note: 72, velocity: 0))])
        XCTAssertEqual(router.heldNoteCount, 0)
    }

    func testDeletingRouteFlushesHeldNotes() {
        let router = MIDIRouter(routes: [MIDIRoute(source: keys, destination: moog)])
        _ = router.process(.noteOn(channel: 0, note: 50, velocity: 100), from: keys)
        let flush = router.setRoutes([])
        XCTAssertEqual(flush, [RoutedMIDI(moog, .noteOff(channel: 0, note: 50, velocity: 0))])
    }

    func testFilterBlocksClockButPassesNotes() {
        var f = MIDIFilter(); f.clock = false
        let router = MIDIRouter(routes: [MIDIRoute(source: keys, destination: moog, filter: f)])
        XCTAssertEqual(router.process(.clock, from: keys), [])
        XCTAssertEqual(router.process(.noteOn(channel: 0, note: 1, velocity: 1), from: keys).count, 1)
    }

    func testCCRemapAndVelocityFixed() {
        var t = MIDITransform(); t.ccRemap = [1: 74]; t.velocity = .fixed(100)
        let router = MIDIRouter(routes: [MIDIRoute(source: keys, destination: moog, transform: t)])
        XCTAssertEqual(router.process(.controlChange(channel: 0, controller: 1, value: 5), from: keys),
                       [RoutedMIDI(moog, .controlChange(channel: 0, controller: 74, value: 5))])
        XCTAssertEqual(router.process(.noteOn(channel: 0, note: 1, velocity: 3), from: keys),
                       [RoutedMIDI(moog, .noteOn(channel: 0, note: 1, velocity: 100))])
    }

    func testPanicSendsAllNotesOff() {
        let router = MIDIRouter(routes: [MIDIRoute(source: keys, destination: moog)])
        _ = router.process(.noteOn(channel: 0, note: 50, velocity: 100), from: keys)
        let p = router.panic()
        XCTAssertTrue(p.contains(RoutedMIDI(moog, .noteOff(channel: 0, note: 50, velocity: 0))))
        XCTAssertTrue(p.contains(RoutedMIDI(moog, .controlChange(channel: 15, controller: 123, value: 0))))
    }

    func testMonoTrackerLegatoFallback() {
        var m = MonoNoteTracker()
        m.handle(.noteOn(channel: 0, note: 48, velocity: 100))
        m.handle(.noteOn(channel: 0, note: 55, velocity: 100))
        XCTAssertEqual(m.currentNote, 55)
        m.handle(.noteOff(channel: 0, note: 55, velocity: 0))
        XCTAssertEqual(m.currentNote, 48)
        XCTAssertTrue(m.gate)
        m.handle(.noteOff(channel: 0, note: 48, velocity: 0))
        XCTAssertFalse(m.gate)
        XCTAssertEqual(m.triggerCount, 2)
    }
}
