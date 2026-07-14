import AVFoundation
import Accelerate
import Foundation
import MediaToolbox
import os

/// Extracts live per-band spectrum levels (bass → treble) from playback via
/// an MTAudioProcessingTap and a vDSP FFT.
///
/// Whether the tap ever fires is stream-dependent: the asset must expose an
/// audio track at the asset level (SomaFM's servers do; many other Icecast
/// hosts and HLS don't — verified empirically, headers are no predictor).
/// When it never fires, `read()` reports `isLive: false` and callers fall
/// back to a synthesized animation.
final class LevelMeter {
    private static let fftSize = 1024
    private static let log2n = vDSP_Length(10)

    private struct Shared {
        var bands = SIMD8<Float>()
        var bandCount = 5
        var lastUpdate: TimeInterval = 0
        var sampleRate: Float = 44100
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    /// Serializes FFT scratch-buffer use across briefly overlapping taps
    /// during a station switch; a frame that can't get the lock is dropped.
    private let scratchLock = OSAllocatedUnfairLock()

    private let fftSetup: FFTSetup
    private let window = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
    private let input = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
    private let magsq = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private let realBuf = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private let imagBuf = UnsafeMutablePointer<Float>.allocate(capacity: fftSize / 2)
    private var split: DSPSplitComplex

    init() {
        fftSetup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))!
        split = DSPSplitComplex(realp: realBuf, imagp: imagBuf)
        vDSP_hann_window(window, vDSP_Length(Self.fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        window.deallocate()
        input.deallocate()
        magsq.deallocate()
        realBuf.deallocate()
        imagBuf.deallocate()
    }

    /// Latest band levels (0…1 each, bass → treble) and whether the tap
    /// updated them recently.
    func read() -> (bands: [Float], isLive: Bool) {
        shared.withLock { s in
            ((0..<s.bandCount).map { s.bands[$0] },
             ProcessInfo.processInfo.systemUptime - s.lastUpdate < 1.0)
        }
    }

    /// Sets how many spectrum bands `read()` reports (clamped to 3…8).
    func setBandCount(_ count: Int) {
        let clamped = max(3, min(8, count))
        shared.withLock { $0.bandCount = clamped }
    }

    /// Attaches a level tap to the item's first audio track (once it is known).
    /// Silently does nothing when the asset exposes no audio track or the
    /// stream type doesn't support audio mixes.
    @MainActor
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let meter = Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                meter.shared.withLock { $0.sampleRate = Float(format.pointee.mSampleRate) }
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                         flagsOut, nil, numberFramesOut) == noErr else { return }
                let meter = Unmanaged<LevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                meter.ingest(bufferListInOut, frameCount: numberFramesOut.pointee)
            })

        var tapOut: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                         MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PostEffects),
                                         &tapOut) == noErr,
              let tap = tapOut else {
            Unmanaged.passUnretained(self).release()  // balance passRetained: tap never took ownership
            return
        }

        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
    }

    /// Called on the realtime audio thread; all buffers are preallocated.
    private func ingest(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0, scratchLock.lockIfAvailable() else { return }
        defer { scratchLock.unlock() }

        // Mono analysis of the first channel (PostEffects taps are typically
        // deinterleaved; handle an interleaved layout via stride just in case).
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first(where: { $0.mData != nil }), let data = first.mData else { return }
        let stride = max(Int(first.mNumberChannels), 1)
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / stride
        let n = min(available, min(frameCount, Self.fftSize))
        guard n >= 256 else { return }

        let samples = data.assumingMemoryBound(to: Float.self)
        if stride == 1 {
            input.update(from: samples, count: n)
        } else {
            for i in 0..<n { input[i] = samples[i * stride] }
        }
        if n < Self.fftSize {
            input.advanced(by: n).update(repeating: 0, count: Self.fftSize - n)
        }

        vDSP_vmul(input, 1, window, 1, input, 1, vDSP_Length(Self.fftSize))
        input.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { packed in
            vDSP_ctoz(packed, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
        }
        vDSP_fft_zrip(fftSetup, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
        vDSP_zvmags(&split, 1, magsq, 1, vDSP_Length(Self.fftSize / 2))

        let (sampleRate, bandCount) = shared.withLock { ($0.sampleRate, $0.bandCount) }
        let binWidth = sampleRate / Float(Self.fftSize)
        var levels = SIMD8<Float>()
        for band in 0..<bandCount {
            // log-spaced edges, 40 Hz … 16 kHz regardless of band count
            let loHz = 40 * pow(400, Float(band) / Float(bandCount))
            let hiHz = 40 * pow(400, Float(band + 1) / Float(bandCount))
            let lo = min(max(1, Int(loHz / binWidth)), Self.fftSize / 2 - 1)
            let hi = min(max(lo + 1, Int(hiHz / binWidth)), Self.fftSize / 2)
            var mean: Float = 0
            vDSP_meanv(magsq + lo, 1, &mean, vDSP_Length(hi - lo))
            let amplitude = mean.squareRoot() / Float(Self.fftSize)
            let db = 20 * log10(max(amplitude, 1e-7))
            let tilted = db + Float(band) * (20 / Float(bandCount))  // ≈pink-noise tilt so treble reads
            let level = min(max((tilted + 54) / 44, 0), 1)
            guard level.isFinite else { return }
            levels[band] = level
        }

        let now = ProcessInfo.processInfo.systemUptime
        let final = levels
        shared.withLock { s in
            s.bands = final
            s.lastUpdate = now
        }
    }
}
