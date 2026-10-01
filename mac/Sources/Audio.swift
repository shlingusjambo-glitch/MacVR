import Foundation
import ScreenCaptureKit
import CoreMedia
import os

/// Captures the Mac's system audio (games in Wine included, MacVR itself excluded) with ScreenCaptureKit and
/// hands out 10 ms chunks of 48 kHz stereo s16le for VR4_AUDIO packets.
final class AudioCapture: NSObject, SCStreamOutput {
    static let rate = 48_000, chunkFrames = 480
    private let logger = Logger(subsystem: "com.vr4mac.audio", category: "capture")
    var onChunk: (Data) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    private var stream: SCStream?
    private var pending = Data()
    private let q = DispatchQueue(label: "vr4.audio")
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var starting = false
    private var reportTime = DispatchTime.now().uptimeNanoseconds
    private var reportPackets = 0, reportPeak = 0 // audio queue only

    private func beginStart() -> UInt64? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard stream == nil, !starting else { return nil }
        starting = true
        return generation
    }

    private func finishStart(_ candidate: SCStream?, token: UInt64) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard generation == token else { return false }
        starting = false; stream = candidate
        return true
    }

    func start() {
        guard let token = beginStart() else { return }
        logger.notice("Starting system audio capture")
        Task {
            let content: SCShareableContent
            do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
            catch {
                _ = finishStart(nil, token: token)
                logger.error("Audio shareable content failed: \(String(describing: error), privacy: .public)")
                let denied = (error as NSError).code == -3801
                onError(denied ? "Enable Screen & System Audio Recording for VR4Mac in System Settings, then relaunch." : "Audio capture unavailable: \(error.localizedDescription)")
                return
            }
            guard let display = content.displays.first else {
                _ = finishStart(nil, token: token); logger.error("Audio capture unavailable: no display")
                onError("Audio capture unavailable: no display detected.")
                return
            }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = false // Include VR menu feedback sounds in the headset stream.
            cfg.sampleRate = AudioCapture.rate
            cfg.channelCount = 2
            cfg.width = 2; cfg.height = 2   // a display filter is required; keep its video cost negligible
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
                try await s.startCapture()
                guard finishStart(s, token: token) else { try? await s.stopCapture(); return }
                logger.notice("System audio capture started")
            } catch {
                _ = finishStart(nil, token: token)
                logger.error("Audio capture failed: \(String(describing: error), privacy: .public)")
                onError("Audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        stateLock.lock()
        generation &+= 1; starting = false
        let old = stream; stream = nil
        stateLock.unlock()
        old?.stopCapture { _ in }
        q.async { self.pending.removeAll() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        stateLock.lock(); let active = self.stream === stream; stateLock.unlock()
        guard active else { return }
        guard type == .audio, let fmt = sb.formatDescription?.audioStreamBasicDescription, fmt.mSampleRate == Double(AudioCapture.rate) else { return }
        let frames = CMSampleBufferGetNumSamples(sb)
        var block: CMBlockBuffer?
        let size = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size   // room for 2 buffers
        let list = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { list.deallocate() }
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil,
                bufferListOut: list.assumingMemoryBound(to: AudioBufferList.self), bufferListSize: size,
                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(list.assumingMemoryBound(to: AudioBufferList.self))
        let isFloat = fmt.mFormatFlags & kAudioFormatFlagIsFloat != 0, planar = fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard isFloat, fmt.mBitsPerChannel == 32, frames > 0, frames <= 48_000,
              fmt.mChannelsPerFrame > 0, !buffers.isEmpty else { return }
        let channels = Int(fmt.mChannelsPerFrame)
        if planar {
            guard buffers.count >= min(2, channels), buffers.prefix(min(2, channels)).allSatisfy({ $0.mData != nil && Int($0.mDataByteSize) >= frames * 4 }) else { return }
        } else {
            guard buffers[0].mData != nil, Int(buffers[0].mDataByteSize) >= frames * channels * 4 else { return }
        }
        // interleave + convert to s16le
        var out = [Int16](repeating: 0, count: frames * 2)
        for f in 0..<frames {
            for c in 0..<2 {
                let v: Float
                if planar {
                    let b = buffers[min(c, buffers.count - 1)]
                    v = b.mData!.assumingMemoryBound(to: Float.self)[f]
                } else {
                    let ch = Int(fmt.mChannelsPerFrame)
                    v = buffers[0].mData!.assumingMemoryBound(to: Float.self)[f * ch + min(c, ch - 1)]
                }
                out[f * 2 + c] = v.isFinite ? Int16(max(-1, min(1, v)) * 32767) : 0
            }
        }
        for sample in out { reportPeak = max(reportPeak, abs(Int(sample))) }
        out.withUnsafeBytes { pending.append(contentsOf: $0) }
        let chunkBytes = AudioCapture.chunkFrames * 4
        while pending.count >= chunkBytes {
            var t = UInt64(DispatchTime.now().uptimeNanoseconds)
            var pkt = Data(bytes: &t, count: 8)
            pkt.append(pending.prefix(chunkBytes))
            pending.removeFirst(chunkBytes)
            onChunk(pkt)
            reportPackets += 1
        }
        let now = DispatchTime.now().uptimeNanoseconds
        if now - reportTime >= 5_000_000_000 {
            logger.notice("Captured PCM packets=\(self.reportPackets, privacy: .public), peak=\(self.reportPeak, privacy: .public)/32767")
            reportTime = now; reportPackets = 0; reportPeak = 0
        }
    }
}
