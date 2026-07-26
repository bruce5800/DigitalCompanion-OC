//
//  TTSService.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/4/12.
//

import AVFoundation
import CompanionCore

/// TTS 引擎类型
enum TTSEngine: String, CaseIterable, Identifiable, Codable {
    case apple
    case fishAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple: return "Apple 内置"
        case .fishAudio: return "Fish Audio"
        }
    }
}

/// Apple TTS 的角色音色配置：指定音色(空 = 运行时自动挑最佳) + 音高 + 语速 +
/// 自动挑选时的性别偏好。三个原创角色靠"性别 + pitch + rate"保证可辨，
/// 即使设备只装了 compact 音色也能区分开。
struct AppleVoiceProfile {
    var voiceIdentifier: String? = nil
    var pitch: Float = 1.0
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var preferredGender: AVSpeechSynthesisVoiceGender = .unspecified

    /// 角色预设（克姐沉稳女声 / 深哥温暖男声 / 小欧跳脱男声）。
    /// 具体音色运行时按"最高质量可用"挑，这里只定方向。
    /// 捏人角色可选的声线预设(名称即持久化 key,存 persona.appleVoicePreset)
    static let customChoices: [(id: String, name: String, profile: AppleVoiceProfile)] = [
        ("f_sweet",  "甜美女声", AppleVoiceProfile(pitch: 1.06, rate: AVSpeechUtteranceDefaultSpeechRate * 1.00, preferredGender: .female)),
        ("f_gentle", "温柔女声", AppleVoiceProfile(pitch: 0.97, rate: AVSpeechUtteranceDefaultSpeechRate * 0.94, preferredGender: .female)),
        ("f_lively", "元气女声", AppleVoiceProfile(pitch: 1.10, rate: AVSpeechUtteranceDefaultSpeechRate * 1.06, preferredGender: .female)),
        ("m_deep",   "沉稳男声", AppleVoiceProfile(pitch: 0.88, rate: AVSpeechUtteranceDefaultSpeechRate * 0.93, preferredGender: .male)),
        ("m_warm",   "温暖男声", AppleVoiceProfile(pitch: 0.95, rate: AVSpeechUtteranceDefaultSpeechRate * 0.96, preferredGender: .male)),
        ("m_clear",  "清朗男声", AppleVoiceProfile(pitch: 1.00, rate: AVSpeechUtteranceDefaultSpeechRate * 1.02, preferredGender: .male)),
    ]

    /// 按预设名取 profile(persona.appleVoicePreset → profile);未知名返回 nil
    static func preset(named name: String) -> AppleVoiceProfile? {
        customChoices.first { $0.id == name }?.profile
    }

    static func preset(forPersonaID id: String) -> AppleVoiceProfile {
        switch id {
        case "oc":  // 克姐 — 知性姐姐：女声，沉稳、略慢
            return AppleVoiceProfile(pitch: 0.97,
                                     rate: AVSpeechUtteranceDefaultSpeechRate * 0.96,
                                     preferredGender: .female)
        case "sg":  // 深哥 — 温暖：男声，低沉、平稳
            return AppleVoiceProfile(pitch: 0.90,
                                     rate: AVSpeechUtteranceDefaultSpeechRate * 0.95,
                                     preferredGender: .male)
        case "xo":  // 小欧 — 搞笑：男声，略高、略快、跳脱
            return AppleVoiceProfile(pitch: 1.12,
                                     rate: AVSpeechUtteranceDefaultSpeechRate * 1.08,
                                     preferredGender: .male)
        default:
            return AppleVoiceProfile()
        }
    }
}

/// 文字转语音服务，支持 Apple 内置和 Fish Audio
@MainActor
@Observable
class TTSService: NSObject {

    var isSpeaking = false
    var engine: TTSEngine = .fishAudio

    /// Fish Audio 音色 ID（可在 fish.audio 上查找角色音色）
    var fishAudioReferenceID: String = ""

    /// Apple TTS 角色音色配置（音色 + 音高 + 语速），AppModel 切角色时设置
    var appleVoiceProfile = AppleVoiceProfile()

    /// 口型同步服务（可选注入，由 AppModel 设置）
    weak var lipSyncService: LipSyncService?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    /// 等待本次朗读结束的订阅者；isSpeaking 转 false 时一并唤醒
    private var completionContinuations: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// 等待当前朗读结束；若当前未在朗读，立即返回
    /// 用于 performance 等"说完话再动作"的编排
    func waitForCompletion() async {
        guard isSpeaking else { return }
        await withCheckedContinuation { continuation in
            completionContinuations.append(continuation)
        }
    }

    /// 内部：朗读结束（无论来源），置位 + 唤醒等待方
    private func finishSpeaking() {
        guard isSpeaking else {
            // 已是 false，仍然可能有残留等待者（极罕见，防御式处理）
            let pending = completionContinuations
            completionContinuations.removeAll()
            pending.forEach { $0.resume() }
            return
        }
        isSpeaking = false
        lipSyncService?.stop()
        let pending = completionContinuations
        completionContinuations.removeAll()
        pending.forEach { $0.resume() }
    }

    /// 朗读文本
    func speak(_ text: String, language: String = "zh-CN") {
        stop()

        // 剥离括号里的动作/神态描写（"剧本注释"），TTS 不读、口型也不按它走
        let spoken = Self.stripStageDirections(text)
        guard !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isSpeaking = true

        // 先根据文本生成 viseme 时间线（无时长时按估算 180ms/字）
        // Fish Audio 模式下拿到真实音频后会在 startMetering 里用 player.duration 重新校准
        lipSyncService?.setTextSchedule(spoken, totalDuration: nil)

        switch engine {
        case .apple:
            speakWithApple(spoken, language: language)
        case .fishAudio:
            Task {
                await speakWithFishAudio(spoken)
            }
        }
    }

    /// 去掉 LLM 回复里的"剧本注释"——括号/星号包裹的动作神态描写，只保留要开口说的话。
    /// 支持：全角括号（）、半角括号 ()、方括号 []、星号 *…*
    static func stripStageDirections(_ text: String) -> String {
        // 注：贪婪度用 .*? 以防一句里多处括号被一口气吃掉
        let patterns = [
            "（[^）]*）",       // 全角
            "\\([^)]*\\)",    // 半角
            "\\[[^\\]]*\\]",  // 方括号
            "\\*[^\\*]*\\*"   // *...*
        ]
        var cleaned = text
        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        // 去掉连续空白（全角/半角）并 trim
        cleaned = cleaned.replacingOccurrences(
            of: "[\\s\\u3000]+",
            with: " ",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 停止朗读
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        audioPlayer = nil
        finishSpeaking()
    }

    // MARK: - Apple TTS

    /// 按"最高质量可用"挑该语言的音色：premium > enhanced > default。
    /// 给了 identifier 就用指定音色；否则按性别偏好过滤后挑质量最高的。
    /// 注：enhanced/premium 音色需用户在系统里下载，没装时只能挑到 compact。
    static func bestVoice(language: String,
                          identifier: String?,
                          gender: AVSpeechSynthesisVoiceGender) -> AVSpeechSynthesisVoice? {
        if let id = identifier, !id.isEmpty,
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v
        }
        let two = String(language.prefix(2)).lowercased()
        var candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(two) }
        if gender != .unspecified {
            let matched = candidates.filter { $0.gender == gender }
            if !matched.isEmpty { candidates = matched }
        }
        func rank(_ q: AVSpeechSynthesisVoiceQuality) -> Int {
            switch q {
            case .premium:  return 3
            case .enhanced: return 2
            default:        return 1
            }
        }
        return candidates.max { rank($0.quality) < rank($1.quality) }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    private func speakWithApple(_ text: String, language: String) {
        let profile = appleVoiceProfile
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.bestVoice(language: language,
                                         identifier: profile.voiceIdentifier,
                                         gender: profile.preferredGender)
        utterance.rate = profile.rate
        utterance.pitchMultiplier = profile.pitch
        utterance.volume = 1.0
        synthesizer.speak(utterance)
        // Apple TTS 无法读取振幅，用节律型伪振幅驱动口型
        lipSyncService?.startFallback()
    }

    // MARK: - Fish Audio TTS

    private func speakWithFishAudio(_ text: String) async {
        guard let apiKey = KeychainService.load(forAccount: KeychainService.fishAudioAPIKeyAccount) else {
            print("❌ Fish Audio API Key 未设置，回退到 Apple TTS")
            speakWithApple(text, language: "zh-CN")
            return
        }

        do {
            let audioData = try await requestFishAudio(text: text, apiKey: apiKey)
            try playAudioData(audioData)
        } catch {
            print("❌ Fish Audio 请求失败: \(error)，回退到 Apple TTS")
            speakWithApple(text, language: "zh-CN")
        }
    }

    private func requestFishAudio(text: String, apiKey: String) async throws -> Data {
        let url = URL(string: "https://api.fish.audio/v1/tts")!

        var body: [String: Any] = [
            "text": text,
            "format": "mp3",
            "model": "s2-pro"
        ]

        // 如果设置了音色 ID，使用指定音色
        if !fishAudioReferenceID.isEmpty {
            body["reference_id"] = fishAudioReferenceID
        }

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TTSError.apiError(statusCode: httpResponse.statusCode, message: errorBody)
        }

        return data
    }

    private func playAudioData(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        audioPlayer = player
        player.play()
        // print("🔊 Fish Audio 开始播放（\(data.count) 字节），启动振幅驱动口型")
        // Fish Audio 模式：用真实音频振幅驱动口型
        lipSyncService?.startMetering(player: player)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.finishSpeaking()
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension TTSService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.finishSpeaking()
        }
    }
}

// MARK: - Error

enum TTSError: LocalizedError {
    case invalidResponse
    case apiError(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "TTS 服务无响应"
        case .apiError(let code, let msg): return "TTS 错误 (\(code)): \(msg)"
        }
    }
}
