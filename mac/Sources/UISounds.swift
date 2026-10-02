import Foundation
import AVFoundation

/// UI sound engine: bundled AOSP system UI sounds (Apache-2.0, Resources/sounds), with synthesized
/// tones only as a fallback, played on the Mac through AVAudioPlayer or mixed into the headset stream,
/// with volume / balance / mono applied. Every dashboard interaction triggers one.
///
/// Headset routing hook (3 lines in Engine.frame):
/// after any `play` call, `takePending()` returns the exact stereo PCM that was
/// just heard on the Mac; send it as VR4_AUDIO packets once capture exists.
/// Nothing here assumes the hook: Mac playback works standalone.
final class UISounds {
    static let shared = UISounds()
    private let sr = 44100
    private var players: [AVAudioPlayer] = []
    private let lock = NSLock()
    private var bank: [String: Data] = [:]
    private var pending: [Data] = []

    var volume: Int { get { UserDefaults.standard.object(forKey: "ui.volume") as? Int ?? 70 } set { UserDefaults.standard.set(min(100, max(0, newValue)), forKey: "ui.volume") } }
    var balance: Int { get { UserDefaults.standard.object(forKey: "ui.balance") as? Int ?? 0 } set { UserDefaults.standard.set(min(50, max(-50, newValue)), forKey: "ui.balance") } }
    var mono: Bool { get { UserDefaults.standard.bool(forKey: "ui.mono") } set { UserDefaults.standard.set(newValue, forKey: "ui.mono") } }
    var brightness: Int { get { UserDefaults.standard.object(forKey: "ui.brightness") as? Int ?? 100 } set { UserDefaults.standard.set(min(100, max(20, newValue)), forKey: "ui.brightness") } }
    /// Game/system audio level sent to the headset (balance and mono above apply to it too).
    var streamVolume: Int { get { UserDefaults.standard.object(forKey: "stream.volume") as? Int ?? 100 } set { UserDefaults.standard.set(min(100, max(0, newValue)), forKey: "stream.volume") } }

    private init() {
        bank["tap"] = tone([(880, 0.0, 0.03), (1320, 0.03, 0.03)], dur: 0.07)
        bank["hover"] = tone([(2093, 0.0, 0.012)], dur: 0.025, gain: 0.25)
        bank["on"] = tone([(660, 0.0, 0.05), (880, 0.05, 0.06)], dur: 0.12)
        bank["off"] = tone([(880, 0.0, 0.05), (660, 0.05, 0.06)], dur: 0.12)
        bank["back"] = tone([(440, 0.0, 0.05)], dur: 0.07)
        bank["open"] = tone([(330, 0.0, 0.05), (495, 0.05, 0.05), (660, 0.10, 0.06)], dur: 0.18)
        bank["key"] = tone([(1567, 0.0, 0.02)], dur: 0.04, gain: 0.6)
        bank["error"] = tone([(196, 0.0, 0.09), (147, 0.09, 0.12)], dur: 0.24, gain: 0.7)
        bank["launch"] = sweep(from: 300, to: 1200, dur: 0.3)
        bank["slider"] = tone([(1200, 0.0, 0.015)], dur: 0.03, gain: 0.4)
        bank["pop"] = tone([(523, 0.0, 0.04), (784, 0.035, 0.05), (1047, 0.075, 0.07)], dur: 0.17, gain: 0.6)   // window opens
        bank["grab"] = tone([(330, 0.0, 0.03), (494, 0.025, 0.03)], dur: 0.07, gain: 0.7)
        bank["drop"] = tone([(494, 0.0, 0.03), (330, 0.025, 0.04)], dur: 0.08, gain: 0.6)
        bank["menuOpen"] = sweep(from: 400, to: 900, dur: 0.16)
        bank["menuClose"] = sweep(from: 900, to: 400, dur: 0.14)
        bank["tick"] = tone([(2637, 0.0, 0.008)], dur: 0.015, gain: 0.3)                                   // scroll detent
        bank["step"] = tone([(659, 0.0, 0.05), (988, 0.045, 0.07)], dur: 0.13, gain: 0.55)                 // tour page
        bank["welcome"] = tone([(523, 0.0, 0.12), (659, 0.1, 0.12), (784, 0.2, 0.12), (1047, 0.3, 0.3)], dur: 0.62, gain: 0.6)
        bank["env"] = sweep(from: 220, to: 660, dur: 0.35)                                                   // environment change
        bank["notify"] = tone([(1319, 0.0, 0.08), (1760, 0.08, 0.12)], dur: 0.22, gain: 0.5)
        bank["close"] = bank["menuClose"]
        bank["dismiss"] = sweep(from: 700, to: 350, dur: 0.09)                                              // notification cleared
        bank["lock"] = tone([(988, 0.0, 0.03), (1319, 0.03, 0.03), (1319, 0.07, 0.03)], dur: 0.11, gain: 0.5)   // caps lock
        // Real AOSP UI sounds (Apache-2.0) replace the synth tones; the tones above are the fallback.
        for name in bank.keys + ["close", "keyspace", "keydel", "keyret"] {
            if let u = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds"), let d = try? Data(contentsOf: u), d.count > 44 {
                bank[name] = d
            }
        }
    }

    /// Rendered stereo 16-bit PCM of the last played sounds, for the headset hook.
    func takePending() -> [Data] { lock.lock(); defer { lock.unlock() }; let p = pending; pending = []; return p }

    /// While a headset is streaming, sounds go straight into its audio stream (Engine mixes `takePending()`), not the
    /// Mac speakers, so they aren't also captured from the speakers and heard twice.
    var headsetOnly = false

    func play(_ name: String) {
        guard let wav = bank[name], wav.count >= 44 + 8 else { return }
        let shaped = shape(wav, UISounds.level[name] ?? 1)
        lock.lock(); pending.append(shaped); if pending.count > 32 { pending.removeFirst() }; lock.unlock()
        if headsetOnly { return }
        guard let pl = try? AVAudioPlayer(data: shaped as Data) else { return }
        pl.play()
        lock.lock(); players.append(pl); players.removeAll { !$0.isPlaying }; lock.unlock()
    }

    // MARK: welcome-tour music (bundled sounds/oobe-music.mp3), looped, faded in and out.
    static let musicURL = Bundle.main.url(forResource: "oobe-music", withExtension: "mp3", subdirectory: "sounds") ?? URL(fileURLWithPath: "/dev/null")
    private var music: [Float] = [], musicPos = 0, musicGain: Float = 0, musicTarget: Float = 0   // 48 kHz stereo; lock
    private var musicPlayer: AVAudioPlayer?
    var musicPlaying: Bool { lock.lock(); defer { lock.unlock() }; return musicGain > 0 || musicTarget > 0 }

    func setMusic(_ on: Bool) {
        lock.lock(); let was = musicTarget > 0; musicTarget = on ? 0.9 : 0; lock.unlock()
        guard on != was else { return }
        if on {
            if music.isEmpty, let pcm = Self.decode48k(Self.musicURL) { lock.lock(); music = pcm; musicPos = 0; lock.unlock() }
            if !headsetOnly, let p = try? AVAudioPlayer(contentsOf: Self.musicURL) {
                p.numberOfLoops = -1; p.volume = 0; p.play(); p.setVolume(0.9 * Float(volume) / 100, fadeDuration: 2); musicPlayer = p
            }
        } else if let p = musicPlayer {
            p.setVolume(0, fadeDuration: 2.5); musicPlayer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { p.stop() }
        }
    }
    /// Headset path: adds the next `frames` of looping music (48 kHz stereo) into s16 PCM, with a 2.5 s fade.
    func mixMusic(into pcm: UnsafeMutablePointer<Int16>, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !music.isEmpty, musicGain > 0 || musicTarget > 0 else { return }
        let vol = Float(volume) / 100, step: Float = 1 / (48_000 * 2.5)
        for i in 0..<frames {
            musicGain += max(-step, min(step, musicTarget - musicGain))
            for c in 0..<2 { pcm[2 * i + c] = Int16(max(-32768, min(32767, Float(pcm[2 * i + c]) + music[musicPos + c] * musicGain * vol * 32767))) }
            musicPos = (musicPos + 2) % music.count
        }
    }
    private static func decode48k(_ url: URL) -> [Float]? {
        guard let f = try? AVAudioFile(forReading: url), let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let conv = AVAudioConverter(from: f.processingFormat, to: fmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)), (try? f.read(into: inBuf)) != nil,
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(f.length) * 48_000 / f.processingFormat.sampleRate) + 4096)
        else { return nil }
        var fed = false
        conv.convert(to: out, error: nil) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return inBuf }
        guard let ch = out.floatChannelData, out.frameLength > 0 else { return nil }
        let n = Int(out.frameLength), r = out.format.channelCount > 1 ? 1 : 0
        var pcm = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { pcm[2 * i] = ch[0][i]; pcm[2 * i + 1] = ch[r][i] }
        return pcm
    }

    // MARK: synthesis (44.1 kHz stereo s16 WAV, volume/balance/mono in the mix)
    /// Quest-style restraint: hover and scroll ticks sit well under clicks; clicks under game audio.
    private static let level: [String: Float] = ["hover": 0.3, "tick": 0.45, "tap": 0.7, "slider": 0.6]
    private func shape(_ wav: Data, _ level: Float = 1) -> Data {
        let n = (wav.count - 44) / 4
        var out = Data(count: wav.count)
        out.replaceSubrange(0..<44, with: wav[0..<44])
        let g = Float(volume) / 100 * level, pan = Float(balance) / 50
        let gl = mono ? g : g * min(1, 1 - pan), gr = mono ? g : g * min(1, 1 + pan)
        wav.withUnsafeBytes { (s: UnsafeRawBufferPointer) in
            out.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) in
                let si = s.bindMemory(to: Int16.self), di = d.bindMemory(to: Int16.self)
                for i in 0..<n {
                    let m = Int16((Int(si[2 * i]) + Int(si[2 * i + 1])) / 2)
                    let l = mono ? m : si[2 * i], r = mono ? m : si[2 * i + 1]
                    di[2 * i] = Int16(max(-32768, min(32767, Int(Float(l) * gl))))
                    di[2 * i + 1] = Int16(max(-32768, min(32767, Int(Float(r) * gr))))
                }
            }
        }
        return out
    }

    private func envelope(_ i: Int, _ n: Int) -> Float {
        let a = min(1, Float(i) / (Float(n) * 0.08 + 1)), r = min(1, Float(n - i) / (Float(n) * 0.25 + 1))
        return min(a, r)
    }

    private func tone(_ parts: [(freq: Float, start: Float, len: Float)], dur: Float, gain: Float = 0.8) -> Data {
        let n = Int(Float(sr) * dur)
        var pcm = [Int16](repeating: 0, count: n * 2)
        for (f, s, l) in parts {
            let b = Int(s * Float(sr)), e = min(n, b + Int(l * Float(sr)))
            for i in b..<e {
                let v = sin(2 * .pi * f * Float(i - b) / Float(sr)) * gain * envelope(i - b, e - b) * 30000
                pcm[2 * i] += Int16(v / Float(parts.count)); pcm[2 * i + 1] += Int16(v / Float(parts.count))
            }
        }
        return wav(pcm)
    }

    private func sweep(from f0: Float, to f1: Float, dur: Float) -> Data {
        let n = Int(Float(sr) * dur)
        var pcm = [Int16](repeating: 0, count: n * 2)
        var phase: Float = 0
        for i in 0..<n {
            phase += 2 * .pi * (f0 + (f1 - f0) * Float(i) / Float(n)) / Float(sr)
            let v = sin(phase) * 0.7 * envelope(i, n) * 30000
            pcm[2 * i] = Int16(v); pcm[2 * i + 1] = Int16(v)
        }
        return wav(pcm)
    }

    private func wav(_ pcm: [Int16]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: [0x52, 0x49, 0x46, 0x46]); u32(UInt32(36 + pcm.count * 2))
        d.append(contentsOf: [0x57, 0x41, 0x56, 0x45, 0x66, 0x6d, 0x74, 0x20]); u32(16); u16(1); u16(2); u32(UInt32(sr)); u32(UInt32(sr * 4)); u16(4); u16(16)
        d.append(contentsOf: [0x64, 0x61, 0x74, 0x61]); u32(UInt32(pcm.count * 2))
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
