import AVFoundation
import Observation

// MARK: - 声音事件

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

// MARK: - 音频引擎

@Observable
final class AudioEngine {

    // MARK: 静音状态

    private var manualMute = false

    var isMuted: Bool {
        get { manualMute || isQuietHoursActive }
        set {
            manualMute = newValue
            UserDefaults.standard.set(newValue, forKey: "audio.isMuted")
        }
    }

    /// 当前是否处于免打扰时段（quiet hours）。
    var isQuietHoursActive: Bool {
        guard UserDefaults.standard.bool(forKey: "audio.quietHoursEnabled") else { return false }
        guard let start = Self.minutesOfDay(from: UserDefaults.standard.string(forKey: "audio.quietHoursStart")),
              let end = Self.minutesOfDay(from: UserDefaults.standard.string(forKey: "audio.quietHoursEnd")) else {
            return false
        }

        let now = Self.currentMinutesOfDay()
        if start <= end {
            return now >= start && now < end
        }
        // 跨午夜时段（如 22:00 ~ 06:00）
        return now >= start || now < end
    }

    // MARK: 音量

    var volume: Float = 0.5 {
        didSet { UserDefaults.standard.set(volume, forKey: "audio.volume") }
    }

    // MARK: 事件开关与声音包

    private(set) var eventEnabled: [SoundEvent: Bool] = [:]
    private var customSounds: [SoundEvent: URL] = [:]
    private(set) var soundPackName: String?

    private let audioQueue = DispatchQueue(label: "dev.xisland.audio")

    init() {
        manualMute = UserDefaults.standard.bool(forKey: "audio.isMuted")

        let savedVolume = UserDefaults.standard.float(forKey: "audio.volume")
        volume = savedVolume > 0 ? savedVolume : 0.5

        restoreEventPreferences()

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

    // MARK: 静音规则

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

    // MARK: 播放

    func play(_ event: SoundEvent, session: AgentSession? = nil) {
        guard !isMuted, isEnabled(event) else { return }

        if let session, muteRules.contains(where: { $0.matches(session: session, event: event) }) {
            return
        }

        audioQueue.async { [weak self] in
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

    // MARK: 声音包管理

    func loadSoundPack(from directory: URL) {
        customSounds.removeAll()
        soundPackName = nil

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }

        let supportedExtensions: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]

        for file in files where supportedExtensions.contains(file.pathExtension.lowercased()) {
            let eventName = normalizedBaseName(of: file)
            if let event = SoundEvent(rawValue: eventName) {
                customSounds[event] = file
            }
        }

        if customSounds.isEmpty {
            UserDefaults.standard.removeObject(forKey: "audio.soundPackPath")
        } else {
            soundPackName = directory.lastPathComponent
            UserDefaults.standard.set(directory.path, forKey: "audio.soundPackPath")
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

    // MARK: 引擎生命周期

    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var currentFormat: AVAudioFormat?

    private func prepareEngine(format: AVAudioFormat) -> (AVAudioEngine, AVAudioPlayerNode)? {
        if let engine, let playerNode, currentFormat == format, engine.isRunning {
            playerNode.stop()
            return (engine, playerNode)
        }

        disposeEngine()

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: format)
        newEngine.mainMixerNode.outputVolume = volume

        do {
            try newEngine.start()
        } catch {
            print("[AudioEngine] 引擎启动失败: \(error)")
            return nil
        }

        engine = newEngine
        playerNode = newPlayer
        currentFormat = format
        return (newEngine, newPlayer)
    }

    private func disposeEngine() {
        playerNode?.stop()
        engine?.stop()
        playerNode = nil
        engine = nil
        currentFormat = nil
    }

    // MARK: 文件播放

    /// 播放音频文件；失败返回 false，由调用方回退到合成音效。
    private func playFile(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else {
            return false
        }
        guard let (_, player) = prepareEngine(format: file.processingFormat) else {
            return false
        }

        player.scheduleFile(file, at: nil) { [weak self, weak player] in
            self?.audioQueue.async { player?.stop() }
        }
        player.play()
        return true
    }

    // MARK: 8-bit 合成

    private struct SynthNote {
        let frequency: Double
        let duration: Double
    }

    private func synthesize(_ event: SoundEvent) {
        playToneSequence(synthNotes(for: event))
    }

    private func synthNotes(for event: SoundEvent) -> [SynthNote] {
        switch event {
        case .sessionStart:
            return [
                SynthNote(frequency: 523.25, duration: 0.08),
                SynthNote(frequency: 659.25, duration: 0.08),
                SynthNote(frequency: 783.99, duration: 0.12),
            ]
        case .sessionEnd:
            return [
                SynthNote(frequency: 783.99, duration: 0.1),
                SynthNote(frequency: 659.25, duration: 0.1),
                SynthNote(frequency: 523.25, duration: 0.15),
            ]
        case .permissionRequest:
            return [
                SynthNote(frequency: 880.0, duration: 0.06),
                SynthNote(frequency: 0, duration: 0.04),
                SynthNote(frequency: 880.0, duration: 0.06),
                SynthNote(frequency: 0, duration: 0.04),
                SynthNote(frequency: 1108.73, duration: 0.1),
            ]
        case .question:
            return [
                SynthNote(frequency: 659.25, duration: 0.1),
                SynthNote(frequency: 783.99, duration: 0.15),
            ]
        case .planReview:
            return [
                SynthNote(frequency: 440.0, duration: 0.08),
                SynthNote(frequency: 523.25, duration: 0.08),
                SynthNote(frequency: 659.25, duration: 0.12),
            ]
        case .approved:
            return [
                SynthNote(frequency: 523.25, duration: 0.06),
                SynthNote(frequency: 783.99, duration: 0.12),
            ]
        case .denied:
            return [
                SynthNote(frequency: 440.0, duration: 0.1),
                SynthNote(frequency: 349.23, duration: 0.15),
            ]
        case .answered:
            return [
                SynthNote(frequency: 659.25, duration: 0.08),
                SynthNote(frequency: 523.25, duration: 0.1),
            ]
        case .toolStart:
            return [
                SynthNote(frequency: 587.33, duration: 0.05),
                SynthNote(frequency: 698.46, duration: 0.07),
            ]
        case .contextCompacting:
            return [
                SynthNote(frequency: 392.0, duration: 0.06),
                SynthNote(frequency: 523.25, duration: 0.06),
                SynthNote(frequency: 392.0, duration: 0.06),
            ]
        case .error:
            return [
                SynthNote(frequency: 220.0, duration: 0.15),
                SynthNote(frequency: 0, duration: 0.05),
                SynthNote(frequency: 220.0, duration: 0.15),
            ]
        }
    }

    private func playToneSequence(_ notes: [SynthNote]) {
        let sampleRate = 44100.0
        let frameCount = notes.reduce(0) { $0 + Int(sampleRate * $1.duration) }

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        render(notes, into: buffer, sampleRate: sampleRate)

        guard let (_, player) = prepareEngine(format: format) else { return }

        player.scheduleBuffer(buffer) { [weak self, weak player] in
            self?.audioQueue.async { player?.stop() }
        }
        player.play()
    }

    /// 将音符序列渲染为单声道 8-bit 方波 PCM 样本。
    private func render(_ notes: [SynthNote], into buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let samples = buffer.floatChannelData?[0] else { return }

        var writeIndex = 0
        for note in notes {
            let frameCount = Int(sampleRate * note.duration)

            guard note.frequency > 0 else {
                for _ in 0..<frameCount {
                    samples[writeIndex] = 0
                    writeIndex += 1
                }
                continue
            }

            let fadeLength = min(100, frameCount / 4)
            for i in 0..<frameCount {
                let t = Double(i) / sampleRate
                let phase = 2.0 * Double.pi * note.frequency * t
                let square: Double = sin(phase) > 0 ? 1.0 : -1.0
                let envelope = Self.envelope(at: i, frameCount: frameCount, fadeLength: fadeLength)
                samples[writeIndex] = Float(square * envelope * Double(volume) * 0.25)
                writeIndex += 1
            }
        }
    }

    /// 计算单个样本的线性淡入淡出包络。
    private static func envelope(at index: Int, frameCount: Int, fadeLength: Int) -> Double {
        if index < fadeLength {
            return Double(index) / Double(fadeLength)
        }
        if index > frameCount - fadeLength {
            return Double(frameCount - index) / Double(fadeLength)
        }
        return 1.0
    }

    // MARK: 时间解析

    private static func minutesOfDay(from text: String?) -> Int? {
        guard let text else { return nil }

        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2,
              parts[1].count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func currentMinutesOfDay() -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    // MARK: 声音包文件名归一化

    private func normalizedBaseName(of file: URL) -> String {
        file.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
    }

    private func restoreEventPreferences() {
        for event in SoundEvent.allCases {
            let key = "audio.event.\(event.rawValue)"
            if UserDefaults.standard.object(forKey: key) != nil {
                eventEnabled[event] = UserDefaults.standard.bool(forKey: key)
            } else {
                eventEnabled[event] = event.enabledByDefault
            }
        }
    }
}
