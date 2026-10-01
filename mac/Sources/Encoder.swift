import Foundation
import VideoToolbox

/// Low-latency hardware H.264 encoder. Emits Annex-B with SPS/PPS in front of every IDR.
final class Encoder {
    private var session: VTCompressionSession?
    private(set) var width = 0, height = 0
    private(set) var hevc = false
    private var frameNo: Int64 = 0
    var forceIDR = true
    private var loggedError = false
    var onFrame: (_ annexB: Data, _ idr: Bool, _ timeNs: UInt64) -> Void = { _, _, _ in }

    func configure(width w: Int, height h: Int, fps: Int, mbps: Int, maxQP: Int, hevc useHEVC: Bool = false) {
        if let s = session { VTCompressionSessionInvalidate(s) }
        width = w; height = h; forceIDR = true; hevc = useHEVC
        let spec = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true] as CFDictionary
        VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: useHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                   encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard let s = session else { return }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: useHEVC ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: mbps * 1_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 10,
            kVTCompressionPropertyKey_MaxFrameDelayCount: 0,
            // explicit Rec.709 so the headset decoder doesn't guess the colour range/matrix (washed-out colours)
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            // cap bursts (IDRs) at 2x the average over a quarter second so frames don't queue behind them
            kVTCompressionPropertyKey_DataRateLimits: [mbps * 1_000_000 / 8 / 2, 0.25] as CFArray,
        ]
        for (k, v) in props { VTSessionSetProperty(s, key: k, value: v as CFTypeRef) }
        // low-latency rate control undershoots badly on simple scenes; a QP ceiling keeps text/edges sharp. Too low a ceiling
        // makes VT *drop* detailed frames it can't fit under DataRateLimits (BONELAB lost ~8%), so it only guards quality.
        let st = VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: maxQP as CFTypeRef)
        NSLog("VR4Mac: %@ encoder %dx%d @ %d fps, %d Mbps, max QP %d (%@)", useHEVC ? "HEVC" : "H.264", w, h, fps, mbps, maxQP, st == noErr ? "ok" : "unsupported \(st)")
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    func encode(_ pb: CVPixelBuffer, timeNs: UInt64) {
        guard let s = session else { return }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let opts = forceIDR ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        forceIDR = false
        frameNo += 1
        // Real capture time: rate control budgets bits per second from PTS spacing. Counting frames as 1 ms apart told VT
        // it had 1000 fps, so slow games (BONELAB ~33 fps) got a tiny per-frame budget and frames were dropped.
        let pts = CMTime(value: CMTimeValue(DispatchTime.now().uptimeNanoseconds / 1000), timescale: 1_000_000)
        VTCompressionSessionEncodeFrame(s, imageBuffer: pb, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: opts, infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else {
                if status != noErr, self?.loggedError == false { self?.loggedError = true; NSLog("VR4Mac: encode failed %d", status) }
                return
            }
            let (data, idr) = Encoder.annexB(sb, hevc: self.hevc)
            self.onFrame(data, idr, timeNs)
        }
    }

    static func annexB(_ sb: CMSampleBuffer, hevc: Bool = false) -> (Data, Bool) {
        let start: [UInt8] = [0, 0, 0, 1]
        var out = Data()
        let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let idr = !(att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if idr, let fmt = CMSampleBufferGetFormatDescription(sb) {   // SPS/PPS (+VPS for HEVC) in front of every IDR
            let get = hevc ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex : CMVideoFormatDescriptionGetH264ParameterSetAtIndex
            var n = 0
            get(fmt, 0, nil, nil, &n, nil)
            for i in 0..<n {
                var p: UnsafePointer<UInt8>?, len = 0
                get(fmt, i, &p, &len, nil, nil)
                if let p { out.append(contentsOf: start); out.append(p, count: len) }
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return (out, idr) }
        var total = 0, ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &total, dataPointerOut: &ptr)
        guard let ptr else { return (out, idr) }
        let raw = UnsafeRawPointer(ptr)
        var off = 0
        while off + 4 <= total {   // AVCC 4-byte big-endian lengths -> start codes
            let len = Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: off, as: UInt32.self)))
            off += 4
            guard off + len <= total else { break }
            out.append(contentsOf: start)
            out.append(raw.advanced(by: off).assumingMemoryBound(to: UInt8.self), count: len)
            off += len
        }
        return (out, idr)
    }
}
