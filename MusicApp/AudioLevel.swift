import AVFoundation
import MediaToolbox
import Accelerate
import QuartzCore

/// Thread-safe scalar shared between the real-time audio thread (writer) and the main thread (reader).
/// A 4-byte aligned `Float` load/store is atomic on ARM64, so no lock is needed for a smoothed visual
/// level — a torn read can't happen and a stale frame is harmless.
final class RawLevelBox: @unchecked Sendable {
    nonisolated(unsafe) var value: Float = 0
}

/// Meters the player's live audio via an `MTAudioProcessingTap` and publishes a smoothed 0…1 level
/// (`onLevel`, ~30 Hz on the main thread) so the playing-indicator bars actually react to the music —
/// like the iPhone Dynamic Island.
@MainActor
final class AudioLevelMonitor {
    var onLevel: ((Double) -> Void)?

    private let box = RawLevelBox()
    private var displayLink: CADisplayLink?
    private var smoothed: Float = 0

    /// Attach a metering tap to a freshly-created player item (call before it plays).
    func installTap(on item: AVPlayerItem) {
        let box = self.box
        Task {
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
            guard let tap = makeMeteringTap(box) else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
    }

    func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        smoothed = 0
        box.value = 0
        onLevel?(0)
    }

    @objc private func tick() {
        // Map RMS (typically ~0…0.3 for music) into 0…1 with an expanded curve, then smooth with a
        // fast attack / moderate release so it FOLLOWS the envelope (dips between beats) instead of
        // peak-holding near a constant value — that was making the bars look almost still.
        let target = min(1, powf(box.value * 7, 0.75))
        smoothed += (target - smoothed) * (target > smoothed ? 0.5 : 0.3)
        onLevel?(Double(smoothed))
    }
}

// MARK: - MTAudioProcessingTap (C callbacks — must be non-capturing)

private func makeMeteringTap(_ box: RawLevelBox) -> MTAudioProcessingTap? {
    let retained = Unmanaged.passRetained(box)
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        clientInfo: UnsafeMutableRawPointer(retained.toOpaque()),
        init: tapInit,
        finalize: tapFinalize,
        prepare: nil,
        unprepare: nil,
        process: tapProcess)

    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    guard status == noErr else { retained.release(); return nil }
    return tap
}

private func tapInit(_ tap: MTAudioProcessingTap,
                     _ clientInfo: UnsafeMutableRawPointer?,
                     _ storageOut: UnsafeMutablePointer<UnsafeMutableRawPointer?>) {
    storageOut.pointee = clientInfo
}

private func tapFinalize(_ tap: MTAudioProcessingTap) {
    Unmanaged<RawLevelBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private func tapProcess(_ tap: MTAudioProcessingTap,
                        _ numberFrames: CMItemCount,
                        _ flags: MTAudioProcessingTapFlags,
                        _ bufferListInOut: UnsafeMutablePointer<AudioBufferList>,
                        _ numberFramesOut: UnsafeMutablePointer<CMItemCount>,
                        _ flagsOut: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
    guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut) == noErr
    else { return }

    let box = Unmanaged<RawLevelBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    var sumOfMeanSquares: Float = 0
    var totalSamples: Float = 0
    for buffer in buffers {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
        let n = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
        var meanSquare: Float = 0
        vDSP_measqv(data.assumingMemoryBound(to: Float.self), 1, &meanSquare, n)
        sumOfMeanSquares += meanSquare * Float(n)
        totalSamples += Float(n)
    }
    if totalSamples > 0 { box.value = sqrtf(sumOfMeanSquares / totalSamples) }
}
