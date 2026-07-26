//
//  LipSyncService.swift
//  DigitalCompanion
//
//  口型同步服务：
//  - Phase 1：根据 TTS 音频振幅驱动主口型 blend shape 权重
//  - Phase 2：根据文本音素时间线，决定当前应该张开的是哪个 viseme（あいうえお）
//

import AVFoundation
import Foundation

/// 口型同步服务
@MainActor
@Observable
class LipSyncService {

    /// 当前嘴巴张开程度（0 = 闭嘴，1 = 完全张开），由振幅驱动
    private(set) var mouthOpenness: Float = 0

    /// 当前主导的 viseme（根据文本时间线）
    /// nil 表示未设置文本时间线（退化为 Phase 1 的纯振幅模式）
    private(set) var currentViseme: Viseme?

    /// 每次 openness 或 viseme 更新时的回调
    /// 参数：(嘴巴张开度 0-1, 当前 viseme)
    var onLipSyncUpdate: ((Float, Viseme?) -> Void)?

    // MARK: - 参数

    private let smoothing: Float = 0.55
    private let minDB: Float = -45
    private let maxDB: Float = -8

    // MARK: - 内部状态

    private var meterTimer: Timer?
    private weak var audioPlayer: AVAudioPlayer?

    private var fallbackTimer: Timer?
    private var fallbackPhase: Float = 0

    /// 当前文本的 viseme 时间线
    private var schedule: [VisemeSegment] = []
    /// 时间线开始时间戳（用于计算当前处于哪个 segment）
    private var scheduleStartTime: Date?

    /// 表演(唱歌)模式的预计算口型曲线
    private var curve: MouthCurve?
    private var curveVisemeStep = 0
    private var curveWasAboveOnset = false

    // MARK: - 配置文本时间线

    /// 在说话开始前调用，设置文本 + 预估总时长
    /// - 对 Fish Audio：totalDuration 可在获得 audioPlayer 后从 player.duration 取精确值
    /// - 对 Apple TTS：先用估算，开始说话时再设 scheduleStartTime
    func setTextSchedule(_ text: String, totalDuration: TimeInterval?) {
        schedule = VisemeMapper.schedule(from: text, totalDuration: totalDuration)
        scheduleStartTime = nil
        // print("📝 Viseme 时间线：\(schedule.count) 个音节，总时长 ≈ \(String(format: "%.2f", totalDuration ?? Double(schedule.count) * 0.18))s")
    }

    /// 清除时间线（回退到 Phase 1 纯振幅模式）
    func clearSchedule() {
        schedule = []
        scheduleStartTime = nil
        currentViseme = nil
    }

    /// 根据当前时间更新 currentViseme
    private func updateCurrentViseme() {
        guard let start = scheduleStartTime, !schedule.isEmpty else {
            currentViseme = nil
            return
        }
        let elapsed = Date().timeIntervalSince(start)

        // 二分查找当前 segment
        for seg in schedule {
            if elapsed >= seg.startTime && elapsed < seg.endTime {
                currentViseme = seg.viseme
                return
            }
        }
        // 超出时间线：保持最后一个 viseme
        currentViseme = schedule.last?.viseme
    }

    // MARK: - Fish Audio 模式

    func startMetering(player: AVAudioPlayer) {
        stop()
        player.isMeteringEnabled = true
        audioPlayer = player

        // 有了真实音频后，用 player.duration 重新校准时间线
        if !schedule.isEmpty && player.duration > 0 {
            let count = schedule.count
            let perDuration = player.duration / Double(count)
            schedule = schedule.enumerated().map { i, seg in
                VisemeSegment(viseme: seg.viseme, startTime: Double(i) * perDuration, duration: perDuration)
            }
            // print("🎯 用真实音频时长 \(String(format: "%.2f", player.duration))s 校准了 viseme 时间线")
        }

        scheduleStartTime = Date()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickMetering()
            }
        }
    }

    private func tickMetering() {
        guard let player = audioPlayer, player.isPlaying else {
            fadeOut()
            return
        }
        player.updateMeters()
        let db = player.averagePower(forChannel: 0)

        let clamped = max(minDB, min(maxDB, db))
        let normalized = (clamped - minDB) / (maxDB - minDB)

        mouthOpenness = mouthOpenness * (1 - smoothing) + normalized * smoothing
        updateCurrentViseme()
        onLipSyncUpdate?(mouthOpenness, currentViseme)
    }

    // MARK: - Apple TTS 回退模式

    func startFallback() {
        stop()
        fallbackPhase = 0
        scheduleStartTime = Date()

        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickFallback()
            }
        }
    }

    private func tickFallback() {
        fallbackPhase += 0.15
        let base = (sin(fallbackPhase) * 0.35 + sin(fallbackPhase * 2.3) * 0.2) + 0.45
        let jitter = Float.random(in: -0.08...0.08)
        let target = max(0, min(1, base + jitter))
        mouthOpenness = mouthOpenness * (1 - smoothing) + target * smoothing
        updateCurrentViseme()
        onLipSyncUpdate?(mouthOpenness, currentViseme)
    }

    // MARK: - 停止

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        audioPlayer = nil
        scheduleStartTime = nil
        currentViseme = nil
        curve = nil
        fadeOut()
    }

    private func fadeOut() {
        mouthOpenness *= 0.3
        if mouthOpenness < 0.02 { mouthOpenness = 0 }
        onLipSyncUpdate?(mouthOpenness, currentViseme)
    }

    // MARK: - 表演(唱歌)曲线模式

    /// 唱歌 viseme 轮换序列:张口元音为主,在音节起始处轮换,
    /// 咬字观感比全程固定一个口型自然
    private static let singingVisemePattern: [Viseme] = [.a, .e, .a, .o, .i, .a, .u, .e]
    /// 包络从静默上穿该阈值视为一个新音节的起始
    private let curveOnsetThreshold: Float = 0.18

    /// 表演模式:按预计算的口型包络曲线驱动嘴形,
    /// 采样点跟随 player.currentTime,天然与音频对齐(不怕加载/启动延迟)
    func startCurve(_ curve: MouthCurve, player: AVAudioPlayer) {
        stop()
        self.curve = curve
        audioPlayer = player
        curveVisemeStep = 0
        curveWasAboveOnset = false
        currentViseme = Self.singingVisemePattern[0]

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickCurve()
            }
        }
    }

    private func tickCurve() {
        guard let curve, let player = audioPlayer, player.isPlaying else {
            fadeOut()
            return
        }
        let target = curve.openness(at: player.currentTime)

        // 音节起始处轮换 viseme
        let above = target >= curveOnsetThreshold
        if above && !curveWasAboveOnset {
            curveVisemeStep = (curveVisemeStep + 1) % Self.singingVisemePattern.count
        }
        curveWasAboveOnset = above

        currentViseme = Self.singingVisemePattern[curveVisemeStep]
        mouthOpenness = mouthOpenness * (1 - smoothing) + target * smoothing
        onLipSyncUpdate?(mouthOpenness, currentViseme)
    }
}
