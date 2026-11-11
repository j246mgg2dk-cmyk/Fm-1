import XCTest
@testable import FM1Core

final class TransportTests: XCTestCase {
    func testClockTicksPerBeat() {
        let gen = MIDIClockGenerator()
        // One beat at 120 BPM / 48 kHz = 24000 frames, in a single block.
        let ticks = gen.tickOffsets(beatRange: 0..<1, frames: 24000)
        XCTAssertEqual(ticks.count, 24)
        XCTAssertEqual(ticks.first, 0)
        XCTAssertEqual(ticks[1], 1000)
    }

    func testClockTicksAcrossBlocksHaveNoGapsOrDoubles() {
        var t = Transport(tempo: 133)
        t.play(from: 0)
        let gen = MIDIClockGenerator()
        var total = 0
        for _ in 0..<1000 {
            let r = t.advance(frames: 256, sampleRate: 48000)
            total += gen.tickOffsets(beatRange: r, frames: 256).count
        }
        let beats = t.beatPosition
        XCTAssertEqual(Double(total), (beats * 24).rounded(.up), accuracy: 1)
    }

    func testClockFollowerEstimatesTempoWithJitter() {
        var f = MIDIClockFollower()
        var rng = SplitMix64(seed: 1)
        let interval = 60.0 / (97.0 * 24)
        var time = 0.0
        for _ in 0..<96 {
            f.handle(.clock, at: time + (rng.nextUnit() - 0.5) * 0.002) // ±1 ms BLE jitter
            time += interval
        }
        XCTAssertEqual(f.tempo ?? 0, 97, accuracy: 1.0)
    }

    func testPositionString() {
        var t = Transport()
        t.locate(4 + 1 + 0.5)
        XCTAssertEqual(t.positionString, "2.2.3")
    }

    func testLaunchQuantize() {
        let ts = TimeSignature()
        XCTAssertEqual(LaunchQuantization.bar.nextLaunchBeat(after: 0.1, timeSignature: ts), 4)
        XCTAssertEqual(LaunchQuantization.bar.nextLaunchBeat(after: 8, timeSignature: ts), 8)
        XCTAssertEqual(LaunchQuantization.none.nextLaunchBeat(after: 3.3, timeSignature: ts), 3.3)
        XCTAssertEqual(LaunchQuantization.bar.nextLaunchBeat(after: 1, timeSignature: TimeSignature(7, 8)), 3.5)
    }
}

final class ClipTests: XCTestCase {
    func testLoopingClipEmitsBalancedNotes() {
        let clip = MIDIClipData(notes: [
            NoteEvent(start: 0, length: 0.5, note: 60),
            NoteEvent(start: 1.5, length: 1, note: 64),
            NoteEvent(start: 3.5, length: 2, note: 67), // runs past loop end, must be cut at 4
        ], lengthBeats: 4)
        var player = MIDIClipPlayer(clip: clip, launchBeat: 0)
        var out: [ScheduledMIDI] = []
        var beat = 0.0
        while beat < 16 {
            player.render(beat..<(beat + 0.37), into: &out)
            beat += 0.37
        }
        player.stop(into: &out)
        let ons = out.filter { $0.message.isNoteOn }.count
        let offs = out.filter { $0.message.isNoteOff }.count
        XCTAssertEqual(ons, offs)
        XCTAssertTrue(player.activeNotes.isEmpty)
        XCTAssertGreaterThanOrEqual(ons, 12)
    }

    func testNoteStartingAndEndingInSameBlock() {
        let clip = MIDIClipData(notes: [NoteEvent(start: 0.25, length: 0.1, note: 60)], lengthBeats: 1)
        var player = MIDIClipPlayer(clip: clip, launchBeat: 0)
        var out: [ScheduledMIDI] = []
        player.render(0..<1, into: &out)
        XCTAssertEqual(out.map(\.message), [
            .noteOn(channel: 0, note: 60, velocity: 100),
            .noteOff(channel: 0, note: 60, velocity: 0),
        ])
        XCTAssertEqual(out[0].beatOffset, 0.25, accuracy: 1e-9)
        XCTAssertEqual(out[1].beatOffset, 0.35, accuracy: 1e-9)
    }

    func testLaunchInFutureIsSilentUntilLaunch() {
        let clip = MIDIClipData(notes: [NoteEvent(start: 0, length: 0.5, note: 60)], lengthBeats: 1)
        var player = MIDIClipPlayer(clip: clip, launchBeat: 4)
        var out: [ScheduledMIDI] = []
        player.render(3..<3.9, into: &out)
        XCTAssertTrue(out.isEmpty)
        player.render(3.9..<4.1, into: &out)
        XCTAssertEqual(out.first?.beatOffset ?? -1, 0.1, accuracy: 1e-9)
    }

    func testRecorderRoundsToBars() {
        var r = MIDIClipRecorder(startBeat: 8)
        r.handle(.noteOn(channel: 0, note: 60, velocity: 90), atBeat: 8.5)
        r.handle(.noteOff(channel: 0, note: 60, velocity: 0), atBeat: 9)
        r.handle(.noteOn(channel: 0, note: 62, velocity: 90), atBeat: 13)
        let clip = r.finish(atBeat: 13.5, barLength: 4)
        XCTAssertEqual(clip.lengthBeats, 8)
        XCTAssertEqual(clip.notes.count, 2)
        XCTAssertEqual(clip.notes[0].start, 0.5)
        XCTAssertEqual(clip.quantized(grid: 1).notes[0].start, 1) // 0.5 rounds away from zero
    }
}

final class ModulationTests: XCTestCase {
    func testSyncedLFOIsPhaseLockedToSong() {
        let def = ModulatorDefinition(name: "LFO", kind: .lfo(shape: .sawUp, rate: .beats(4), phaseOffset: 0, bipolar: false))
        var m = ModulatorState(def)
        let v = m.advance(.init(deltaSeconds: 0.01, beatPosition: 2, tempo: 120, isPlaying: true))
        XCTAssertEqual(v, 0.5, accuracy: 1e-9)
    }

    func testADSR() {
        let def = ModulatorDefinition(name: "Env", kind: .adsr(attack: 0.1, decay: 0.1, sustain: 0.5, release: 0.2))
        var m = ModulatorState(def)
        var v = 0.0
        for _ in 0..<10 { v = m.advance(.init(deltaSeconds: 0.01, beatPosition: 0, tempo: 120, isPlaying: false, gate: true)) }
        XCTAssertEqual(v, 1, accuracy: 1e-6)
        for _ in 0..<30 { v = m.advance(.init(deltaSeconds: 0.01, beatPosition: 0, tempo: 120, isPlaying: false, gate: true)) }
        XCTAssertEqual(v, 0.5, accuracy: 1e-6)
        for _ in 0..<30 { v = m.advance(.init(deltaSeconds: 0.01, beatPosition: 0, tempo: 120, isPlaying: false, gate: false)) }
        XCTAssertEqual(v, 0, accuracy: 1e-6)
    }

    func testMatrixSumsAndClamps() {
        let a = ModulatorDefinition(name: "A", kind: .macro(value: 1))
        let b = ModulatorDefinition(name: "B", kind: .macro(value: 1))
        let target = ModulationTarget.trackPan(track: UUID())
        let m = CompiledModulationMatrix(modulators: [a, b], connections: [
            ModulationConnection(modulator: a.id, target: target, depth: 0.3),
            ModulationConnection(modulator: b.id, target: target, depth: 0.4),
        ])
        var out = [0.0]
        m.apply(modulatorOutputs: [1, 1], bases: [0.2], into: &out)
        XCTAssertEqual(out[0], 0.9, accuracy: 1e-9)
        m.apply(modulatorOutputs: [1, 1], bases: [0.5], into: &out)
        XCTAssertEqual(out[0], 1)
    }
}

final class CVTests: XCTestCase {
    func testOneVoltPerOctave() {
        let cfg = CVOutputConfig(name: "Pitch", channel: 2, source: .pitch(track: UUID(), bendRange: 2), zeroVoltNote: 36)
        XCTAssertEqual(cfg.volts(forNote: 48), 1, accuracy: 1e-9)
        XCTAssertEqual(cfg.volts(forNote: 24), -1, accuracy: 1e-9)
        XCTAssertEqual(cfg.calibration.sample(forVolts: 5), 0.5, accuracy: 1e-6)
    }

    func testQuantizer() {
        let q = ScaleQuantizer(root: 0, scale: .minorPentatonic)
        XCTAssertEqual(q.quantize(61), 60)
        XCTAssertEqual(q.quantize(64), 63)
        XCTAssertEqual(q.quantize(71), 70)
        XCTAssertEqual(q.quantize(-1), -2)
    }
}

final class ProjectTests: XCTestCase {
    func testRoundTripAndTrackRemovalCleansRoutes() throws {
        var p = Project(name: "Jam")
        let t = p.addTrack(.externalInstrument)
        p.midiRoutes.append(MIDIRoute(source: EndpointID(.bluetooth, "WIDI"), destination: t.endpoint))
        p.tracks[0].clipSlots[0] = Clip(name: "A", content: .midi(MIDIClipData(notes: [NoteEvent(start: 0, length: 1, note: 60)])))
        let back = try Project.decode(p.encoded())
        XCTAssertEqual(back, p)

        p.removeTrack(t.id)
        XCTAssertTrue(p.midiRoutes.isEmpty)
    }

    func testFourCC() {
        XCTAssertEqual(PluginComponentID.fourCCString(PluginComponentID.fourCC("aumu")), "aumu")
        let c = PluginComponentID(type: PluginComponentID.fourCC("aumi"), subtype: 0, manufacturer: 0, name: "", manufacturerName: "")
        XCTAssertEqual(c.role, .midiProcessor)
    }

    func testFloatRingWrapsAround() {
        let ring = FloatRingBuffer(capacity: 1024)
        var src = [Float](repeating: 0, count: 700)
        var dst = [Float](repeating: 0, count: 700)
        for round in 0..<5 {
            for i in 0..<700 { src[i] = Float(round * 1000 + i) }
            XCTAssertEqual(src.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 700) }, 700)
            XCTAssertEqual(dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 700) }, 700)
            XCTAssertEqual(dst, src)
        }
    }

    func testSPSCQueueOrder() {
        let q = SPSCQueue<RawMIDI>(capacity: 4, initial: RawMIDI())
        for i in 0..<4 { XCTAssertTrue(q.push(RawMIDI(b0: 0x90, b1: UInt8(i), b2: 1, length: 3))) }
        XCTAssertFalse(q.push(RawMIDI()))
        var got: [UInt8] = []
        q.drain { got.append($0.b1) }
        XCTAssertEqual(got, [0, 1, 2, 3])
    }
}
