import AVFoundation
#if canImport(CoreAudio)
import CoreAudio
#endif

/// The phone's own alarm sound: a synthesized two-tone siren (no audio asset needed).
/// Separate from the tag's buzzer, which only the SIREN/STOP commands control.
@MainActor
final class SirenPlayer {
    static let shared = SirenPlayer()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private(set) var isPlaying = false

    /// Phase state shared with the real-time render thread (only touched there).
    private final class Oscillator: @unchecked Sendable {
        var phase = 0.0
        var time = 0.0
        let sampleRate: Double
        init(sampleRate: Double) { self.sampleRate = sampleRate }
    }

    func start(nearby: Bool = false) {
        guard !isPlaying else { return }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .playback plays even with the ring/silent switch on: this is an alarm.
        try? session.setCategory(.playback, mode: .default, options: nearby ? [.mixWithOthers] : [])
        try? session.setActive(true)
        #endif
        let format = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 44_100
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let node = Self.makeSirenNode(format: mono, nearby: nearby)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: mono)
        source = node
        do {
            try engine.start()
            isPlaying = true
        } catch {
            stop()
        }
    }

    /// Built outside the main actor on purpose: Core Audio calls the render block on its
    /// real-time thread, and a closure formed in a @MainActor method would be main-actor
    /// isolated (Swift 6 traps on that at runtime).
    private nonisolated static func makeSirenNode(format: AVAudioFormat, nearby: Bool) -> AVAudioSourceNode {
        let osc = Oscillator(sampleRate: format.sampleRate)
        // Alarm: fast 960/770 Hz alternation. Nearby: slower, softer chirps.
        let (high, low, period, gain) = nearby ? (1320.0, 990.0, 0.6, 0.25) : (960.0, 770.0, 0.45, 0.6)
        return AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, buffers -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(buffers)
            for frame in 0..<Int(frameCount) {
                let freq = osc.time.truncatingRemainder(dividingBy: period) < period / 2 ? high : low
                osc.phase += freq / osc.sampleRate
                if osc.phase >= 1 { osc.phase -= 1 }
                osc.time += 1 / osc.sampleRate
                // Soft square wave (sum of odd harmonics) cuts through noise better than a sine.
                let x = 2 * Double.pi * osc.phase
                let value = Float(gain * (sin(x) + sin(3 * x) / 3 + sin(5 * x) / 5))
                for buffer in list {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
        isPlaying = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
