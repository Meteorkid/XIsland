import AVFoundation
import Observation

enum SoundEvent: String, CaseIterable, Identifiable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case permissionRequest = "permission_request"
    case question = "question"
    case planReview = "plan_review"
    case approved = "approved"
    case denied = "denied"
    case answered = "answered"
    case toolStart = "tool_start"
    case contextCompacting = "context_compacting"
    case error = "error"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sessionStart: "Session start"
        case .sessionEnd: "Session complete"
        case .permissionRequest: "Needs approval"
        case .question: "Question asked"
        case .planReview: "Plan review"
        case .approved: "Approved"
        case .denied: "Denied"
        case .answered: "Answered"
        case .toolStart: "Tool running"
        case .contextCompacting: "Context compacting"
        case .error: "Error"
        }
    }

    var iconSymbol: String {
        switch self {
        case .sessionStart: "play.circle"
        case .sessionEnd: "checkmark.circle"
        case .permissionRequest: "exclamationmark.shield"
        case .question: "questionmark.bubble"
        case .planReview: "doc.text.magnifyingglass"
        case .approved: "hand.thumbsup"
        case .denied: "hand.thumbsdown"
        case .answered: "text.bubble"
        case .toolStart: "wrench.and.screwdriver"
        case .contextCompacting: "arrow.triangle.2.circlepath"
        case .error: "xmark.octagon"
        }
    }

    var enabledByDefault: Bool {
        switch self {
        case .sessionStart, .toolStart, .contextCompacting:
            return false
        default:
            return true
        }
    }
}

@Observable
final class AudioEngine {
    private var _manualMute = false
    var isMuted: Bool {
        get { _manualMute || isQuietHoursActive }
        set {
            _manualMute = newValue
            UserDefaults.standard.set(newValue, forKey: "audio.isMuted")
        }
    }
    var isQuietHoursActive: Bool {
        guard UserDefaults.standard.bool(forKey: "audio.quietHoursEnabled") else { return false }
        guard let start = UserDefaults.standard.string(forKey: "audio.quietHoursStart"),
              let end = UserDefaults.standard.string(forKey: "audio.quietHoursEnd") else { return false }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        guard let startDate = fmt.date(from: start), let endDate = fmt.date(from: end) else { return false }
        let now = Date()
        let cal = Calendar.current
        let nowComp = cal.dateComponents([.hour, .minute], from: now)
        let startComp = cal.dateComponents([.hour, .minute], from: startDate)
        let endComp = cal.dateComponents([.hour, .minute], from: endDate)
        guard let nowMin = cal.date(from: nowComp),
              let startMin = cal.date(from: startComp),
              let endMin = cal.date(from: endComp) else { return false }
        if startMin <= endMin {
            return nowMin >= startMin && nowMin < endMin
        } else {
            return nowMin >= startMin || nowMin < endMin
        }
    }
    var volume: Float = 0.5 {
        didSet { UserDefaults.standard.set(volume, forKey: "audio.volume") }
    }

    private(set) var eventEnabled: [SoundEvent: Bool] = [:]
    private var customSounds: [SoundEvent: URL] = [:]
    private(set) var soundPackName: String?
    private let queue = DispatchQueue(label: "dev.towerisland.audio")

    init() {
        _manualMute = UserDefaults.standard.bool(forKey: "audio.isMuted")
        let savedVol = UserDefaults.standard.float(forKey: "audio.volume")
        volume = savedVol > 0 ? savedVol : 0.5

        for event in SoundEvent.allCases {
            let key = "audio.event.\(event.rawValue)"
            if UserDefaults.standard.object(forKey: key) != nil {
                eventEnabled[event] = UserDefaults.standard.bool(forKey: key)
            } else {
                eventEnabled[event] = event.enabledByDefault
            }
        }

        if let path = UserDefaults.standard.string(forKey: "audio.soundPackPath") {
            loadSoundPack(from: URL(fileURLWithPath: path))
        }
    }

    func isEnabled(_ event: SoundEvent) -> Bool {
        eventEnabled[event] ?? event.enabledByDefault
    }

    func setEnabled(_ event: SoundEvent, _ enabled: Bool) {
        eventEnabled[event] = enabled
        UserDefaults.standard.set(enabled, forKey: "audio.event.\(event.rawValue)")
    }

    var muteRules: [MuteRule] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "audio.muteRules") else { return [] }
            return (try? JSONDecoder().decode([MuteRule].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "audio.muteRules")
            }
        }
    }

    func play(_ event: SoundEvent, session: AgentSession? = nil) {
        guard !isMuted, isEnabled(event) else { return }
        if let session, muteRules.contains(where: { $0.matches(session: session, event: event) }) {
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            if let customURL = self.customSounds[event] {
                if !self.playFile(customURL) {
                    self.synthesize(event)
                }
            } else {
                self.synthesize(event)
            }
        }
    }

    func loadSoundPack(from directory: URL) {
        customSounds.removeAll()
        soundPackName = nil

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let validExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]
        for file in files where validExtensions.contains(file.pathExtension.lowercased()) {
            let name = file.deletingPathExtension().lastPathComponent.lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
            if let event = SoundEvent(rawValue: name) {
                customSounds[event] = file
            }
        }

        if !customSounds.isEmpty {
            soundPackName = directory.lastPathComponent
            UserDefaults.standard.set(directory.path, forKey: "audio.soundPackPath")
        } else {
            UserDefaults.standard.removeObject(forKey: "audio.soundPackPath")
        }
    }

    func clearSoundPack() {
        customSounds.removeAll()
        soundPackName = nil
        UserDefaults.standard.removeObject(forKey: "audio.soundPackPath")
    }

    var hasCustomSoundPack: Bool { !customSounds.isEmpty }

    func hasCustomSound(for event: SoundEvent) -> Bool {
        customSounds[event] != nil
    }

    // MARK: - Shared Engine

    private var _engine: AVAudioEngine?
    private var _player: AVAudioPlayerNode?
    private var _currentFormat: AVAudioFormat?

    private func ensureEngine(format: AVAudioFormat) -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let engine = _engine, let player = _player, _currentFormat == format, engine.isRunning {
            player.stop()
            return (engine, player)
        }

        tearDownEngine()

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume

        do {
            try engine.start()
        } catch {
            print("[AudioEngine] Engine start failed: \(error)")
            return nil
        }

        _engine = engine
        _player = player
        _currentFormat = format
        return (engine, player)
    }

    private func tearDownEngine() {
        _player?.stop()
        _engine?.stop()
        _player = nil
        _engine = nil
        _currentFormat = nil
    }

    // MARK: - File Playback

    /// Returns false if the file could not be opened or the engine failed so callers can fall back to synthesis.
    private func playFile(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else {
            return false
        }

        guard let (_, player) = ensureEngine(format: file.processingFormat) else {
            return false
        }

        player.scheduleFile(file, at: nil) { [weak self, weak player] in
            // completionHandler fires on an internal thread; bounce back to the serial audio queue.
            self?.queue.async { player?.stop() }
        }
        player.play()
        return true
    }

    // MARK: - 8-bit Synthesis

    private func synthesize(_ event: SoundEvent) {
        let tones: [(frequency: Double, duration: Double)]

        switch event {
        case .sessionStart:
            tones = [(523.25, 0.08), (659.25, 0.08), (783.99, 0.12)]
        case .sessionEnd:
            tones = [(783.99, 0.1), (659.25, 0.1), (523.25, 0.15)]
        case .permissionRequest:
            tones = [(880.0, 0.06), (0, 0.04), (880.0, 0.06), (0, 0.04), (1108.73, 0.1)]
        case .question:
            tones = [(659.25, 0.1), (783.99, 0.15)]
        case .planReview:
            tones = [(440.0, 0.08), (523.25, 0.08), (659.25, 0.12)]
        case .approved:
            tones = [(523.25, 0.06), (783.99, 0.12)]
        case .denied:
            tones = [(440.0, 0.1), (349.23, 0.15)]
        case .answered:
            tones = [(659.25, 0.08), (523.25, 0.1)]
        case .toolStart:
            tones = [(587.33, 0.05), (698.46, 0.07)]
        case .contextCompacting:
            tones = [(392.0, 0.06), (523.25, 0.06), (392.0, 0.06)]
        case .error:
            tones = [(220.0, 0.15), (0, 0.05), (220.0, 0.15)]
        }

        playToneSequence(tones)
    }

    private func playToneSequence(_ tones: [(frequency: Double, duration: Double)]) {
        let sampleRate: Double = 44100
        var allSamples: [Float] = []

        for tone in tones {
            let frameCount = Int(sampleRate * tone.duration)
            if tone.frequency == 0 {
                allSamples.append(contentsOf: [Float](repeating: 0, count: frameCount))
                continue
            }

            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let phase = 2.0 * Double.pi * tone.frequency * t
                let square = sin(phase) > 0 ? 1.0 : -1.0

                let fadeLen = min(100, frameCount / 4)
                var envelope = 1.0
                if i < fadeLen {
                    envelope = Double(i) / Double(fadeLen)
                } else if i > frameCount - fadeLen {
                    envelope = Double(frameCount - i) / Double(fadeLen)
                }

                allSamples.append(Float(square * envelope * Double(volume) * 0.25))
            }
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(allSamples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(allSamples.count)
        let channelData = buffer.floatChannelData![0]
        for (i, sample) in allSamples.enumerated() {
            channelData[i] = sample
        }

        guard let (_, player) = ensureEngine(format: format) else {
            return
        }

        player.scheduleBuffer(buffer) { [weak self, weak player] in
            self?.queue.async { player?.stop() }
        }
        player.play()
    }
}
