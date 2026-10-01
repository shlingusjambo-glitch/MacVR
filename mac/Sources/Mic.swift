import AppKit
import AVFoundation
import CoreAudio
import Foundation

/// Settings > Audio > Microphone: a Mac input device, or the headset's own mic.
/// - Mac device: made the macOS default input, which is what Wine and native games record from.
/// - Headset: the Quest streams VR4_MIC packets (CONFIG "mic": true); `onQuestAudio` hands them to the sink
///   (the MacVR virtual input device, which games then see as a normal microphone).
final class Mic {
    static let shared = Mic()
    static let headset = "headset"
    struct Device: Hashable { let id: AudioObjectID; let uid: String; let name: String }

    /// "" = leave the macOS default alone, "headset", or a Mac input device UID.
    var choice: String {
        get { UserDefaults.standard.string(forKey: "mic.choice") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mic.choice"); apply(); onChange() }
    }
    var useHeadset: Bool { choice == Mic.headset }
    /// Engine: re-sends CONFIG so the headset starts/stops capturing.
    var onChange: () -> Void = {}
    /// Sink for headset PCM (mono s16le 48 kHz); the virtual input device plugs in here.
    var onQuestAudio: (Data) -> Void = { _ in }
    private(set) var questPackets = 0
    /// Shown in the picker ("Quest 2 (headset)"); the Engine sets it from HELLO.
    var headsetName = "Quest"
    /// Picker entries: (choice value, label).
    func options() -> [(String, String)] {
        [("", "System default")] + inputs().map { ($0.uid, $0.name) } + [(Mic.headset, "\(headsetName) (headset)")]
    }
    var label: String { options().first { $0.0 == choice }?.1 ?? "System default" }

    /// Input-capable devices, MacVR's own virtual input left out (it is the "headset" choice).
    func inputs() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var n: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &n) == noErr, n > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("MacVR") else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }
    var defaultInputUID: String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr else { return nil }
        return string(id, kAudioDevicePropertyDeviceUID)
    }
    /// Makes `uid` the macOS default input. Returns false if it is not an input device.
    @discardableResult func setDefaultInput(_ uid: String) -> Bool {
        guard let d = inputs().first(where: { $0.uid == uid }) ?? virtualDevice(uid) else { return false }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = d.id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id) == noErr
    }
    /// Re-applies the choice (launch, and whenever devices change).
    func apply() {
        if useHeadset { setDefaultInput(Mic.virtualUID); startFeed() } else { stopFeed(); if !choice.isEmpty { setDefaultInput(choice) } }
        if useHeadset && !virtualInstalled { DispatchQueue.main.async { Mic.offerInstall(force: true) } }
    }
    /// VR4_MIC payload: u64 time_ns + 480 mono s16 samples.
    func receive(_ d: Data) {
        guard useHeadset, d.count > 8 else { return }
        questPackets += 1
        let pcm = d.subdata(in: 8..<d.count)
        onQuestAudio(pcm)
        feedLock.lock()
        pcm.withUnsafeBytes { feed.append(contentsOf: $0.bindMemory(to: Int16.self)) }
        if feed.count > 9600 { feed.removeFirst(feed.count - 2880) }   // >200 ms behind: drop to 60 ms (stay live)
        feedLock.unlock()
    }

    // MARK: playback into the virtual device (its output loops back to its input, which games record)
    private var engine: AVAudioEngine?, feed: [Int16] = [], feedLock = NSLock()
    private func startFeed() {
        guard engine == nil, let dev = virtualDevice(Mic.virtualUID) else { return }
        let e = AVAudioEngine()
        var id = dev.id
        guard let au = e.outputNode.audioUnit,
              AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size)) == noErr,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1) else { return }
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frames, abl in
            let out = UnsafeMutableAudioBufferListPointer(abl)[0].mData!.assumingMemoryBound(to: Float.self)
            guard let self else { for i in 0..<Int(frames) { out[i] = 0 }; return noErr }
            feedLock.lock()
            let n = min(Int(frames), feed.count)
            for i in 0..<n { out[i] = Float(feed[i]) / 32768 }
            for i in n..<Int(frames) { out[i] = 0 }
            feed.removeFirst(n)
            feedLock.unlock()
            return noErr
        }
        e.attach(src); e.connect(src, to: e.mainMixerNode, format: fmt)
        do { try e.start(); engine = e } catch { NSLog("VR4Mac: headset mic feed failed: %@", "\(error)") }
    }
    private func stopFeed() { engine?.stop(); engine = nil; feedLock.lock(); feed.removeAll(); feedLock.unlock() }

    // MARK: install (first launch asks; picking the headset mic asks again if it was skipped)
    /// Asks once, on first launch, to install the driver; `force` asks again (headset mic picked without it).
    static func offerInstall(force: Bool = false) {
        guard !shared.virtualInstalled, force || !UserDefaults.standard.bool(forKey: "mic.offered"),
              let src = Bundle.main.url(forResource: "MacVRMic", withExtension: "driver") else { return }
        UserDefaults.standard.set(true, forKey: "mic.offered")
        let a = NSAlert()
        a.messageText = "Use your headset's microphone in games?"
        a.informativeText = "MacVR adds a small audio driver, “MacVR Headset Mic”, so games can hear your headset's microphone. macOS will ask for your password, and sound may pause for a second."
        a.addButton(withTitle: "Install"); a.addButton(withTitle: "Not Now")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let hal = "/Library/Audio/Plug-Ins/HAL", dst = hal + "/MacVRMic.driver"
        let sh = "mkdir -p '\(hal)' && rm -rf '\(dst)' && cp -R '\(src.path)' '\(dst)' && chown -R root:wheel '\(dst)' && killall coreaudiod"
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(sh)\" with administrator privileges")?.executeAndReturnError(&err)
        if let err { NSLog("VR4Mac: mic driver install failed: %@", err); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { shared.apply() }   // coreaudiod is back: route to the new device
    }

    // MARK: MacVR virtual input device (the "headset" microphone games see)
    static let virtualUID = "MacVRMic_UID"
    var virtualInstalled: Bool { virtualDevice(Mic.virtualUID) != nil }
    private func virtualDevice(_ uid: String) -> Device? {
        guard uid == Mic.virtualUID else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString, id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        let ok = withUnsafeMutablePointer(to: &cf) { p in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<CFString>.size), p, &size, &id) == noErr
        }
        return ok && id != 0 ? Device(id: id, uid: uid, name: "MacVR Headset Mic") : nil
    }

    private func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return nil }
        return s as String
    }
}
