import AVFoundation
import AudioToolbox
import CoreAudio

/// Microphone → 16 kHz mono Float32 chunks for the engine, plus RMS levels (0…1) for the waveform.
/// One instance per recording; `stop()` releases the mic (the orange indicator disappears).
nonisolated final class AudioCapture: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    /// Samples per waveform level: 512 at 16 kHz = 32 ms ≈ 30 levels/s.
    static let levelWindow = 512

    /// Shown via `DictationController` (which localizes it; this class is not on the main actor).
    enum CaptureError: Error {
        case noDevice
        case startFailed(String)
        case tooManyRestarts
    }

    /// Input devices for the Settings picker. `uid` is the AVCaptureDevice uniqueID
    /// (= Core Audio device UID), stored as `AppSettings.microphoneUID`.
    static func availableMicrophones() -> [(uid: String, name: String)] {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices
        var seen = Set<String>()
        return devices.compactMap { d in
            seen.insert(d.uniqueID).inserted ? (uid: d.uniqueID, name: d.localizedName) : nil
        }
    }

    // Callbacks run on the audio tap thread.
    private let onSamples: @Sendable ([Float]) -> Void
    private let onLevels: @Sendable ([Float]) -> Void
    /// The device went away and capture could not be restarted.
    private let onInterrupted: @Sendable () -> Void

    private let engine = AVAudioEngine()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCapture.sampleRate,
                                             channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var running = false
    private var deviceUID: String?
    private var configObserver: NSObjectProtocol?
    private var restarts = 0
    // Tap thread only (the tap is removed before these are reset).
    private var converter: AVAudioConverter?
    private var levelCarry: [Float] = []

    init(onSamples: @escaping @Sendable ([Float]) -> Void,
         onLevels: @escaping @Sendable ([Float]) -> Void,
         onInterrupted: @escaping @Sendable () -> Void) {
        self.onSamples = onSamples
        self.onLevels = onLevels
        self.onInterrupted = onInterrupted
    }

    /// `deviceUID` nil (or not connected) = system default input.
    func start(deviceUID: String?) throws {
        self.deviceUID = deviceUID
        lock.withLock { running = true }
        do {
            try configure()
        } catch {
            lock.withLock { running = false }
            throw error
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.restart() }
        }
    }

    func stop() {
        lock.withLock { running = false }
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Engine

    private func configure() throws {
        let input = engine.inputNode
        if let uid = deviceUID, let id = Self.deviceID(forUID: uid), let unit = input.audioUnit {
            var device = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.noDevice
        }
        converter = nil
        levelCarry = []
        // Format nil = the node's current output format; the converter follows `buffer.format`.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 20), format: nil) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.startFailed(error.localizedDescription)
        }
    }

    /// Device unplugged / format changed: the engine stopped itself; rebuild the tap.
    private func restart() {
        guard lock.withLock({ running }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restarts += 1
        do {
            guard restarts <= 3 else { throw CaptureError.tooManyRestarts }
            try configure()
        } catch {
            stop()
            onInterrupted()
        }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ running }), buffer.frameLength > 0 else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        let feeder = Feeder(buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            feeder.next(inputStatus)
        }
        guard status != .error, out.frameLength > 0, let channel = out.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        onSamples(samples)

        levelCarry.append(contentsOf: samples)
        var levels: [Float] = []
        var offset = 0
        while levelCarry.count - offset >= Self.levelWindow {
            var sum: Float = 0
            for k in offset..<(offset + Self.levelWindow) { sum += levelCarry[k] * levelCarry[k] }
            levels.append(Self.level(rms: (sum / Float(Self.levelWindow)).squareRoot()))
            offset += Self.levelWindow
        }
        levelCarry.removeFirst(offset)
        if !levels.isEmpty { onLevels(levels) }
    }

    /// dB curve: −55 dB (room noise) … −12 dB (loud speech) → 0…1.
    static func level(rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 55) / 43, 0), 1)
    }

    /// Hands one tap buffer to AVAudioConverter, then reports "no data now" so the resampler keeps state.
    private final class Feeder {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let b = buffer else {
                status.pointee = .noDataNow
                return nil
            }
            buffer = nil
            status.pointee = .haveData
            return b
        }
    }

    // MARK: - Core Audio

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
