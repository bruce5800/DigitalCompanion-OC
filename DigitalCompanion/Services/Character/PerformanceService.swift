//
//  PerformanceService.swift
//  DigitalCompanion
//
//  Performance（舞蹈 / 唱歌等长动作）统一编排：
//
//    - 音频是 ground truth：表演时长 = 配乐时长
//    - 角色动画在 ImmersiveView 里自然 loop，audio 结束后由调用方切回 idle
//    - 表演期间「不可打断」：用户输入暂存到 queue，表演结束统一 flush
//
//  调用流程（由 AppModel 编排）：
//    1. LLM 选中 performance 动画 → 标记 pending
//    2. 当前回复 TTS 说完 → await tts.waitForCompletion()
//    3. 切 selectedAnimation → mapping.fileName（动画 loop 起来）
//    4. await performanceService.play(audioFile:) → 音频播完
//    5. 切 selectedAnimation 回 idle
//    6. 若 queue 非空 → 合并后作为一条用户消息自动发送
//

import AVFoundation

@MainActor
@Observable
class PerformanceService: NSObject {

    // MARK: - 状态

    /// 是否正在表演（UI 用来显示"舞蹈中..."并禁用发送）
    private(set) var isPerforming = false

    /// 表演期间暂存的用户消息；performance 结束后合并发送
    private(set) var queuedMessages: [String] = []

    /// 播放真正开始时回调(player + 可选口型曲线);AppModel 用来启动唱歌口型
    var onPlaybackStarted: ((AVAudioPlayer, MouthCurve?) -> Void)?
    /// 播放结束/被打断时回调;AppModel 用来停口型
    var onPlaybackEnded: (() -> Void)?

    // MARK: - 私有

    private var audioPlayer: AVAudioPlayer?
    /// 等待音频播放完成的 continuation（一次性）
    private var playCompletion: CheckedContinuation<Void, Never>?

    // MARK: - 播放

    /// 播放 performance 的配乐，返回时音频已完整播完
    /// - Parameter audioFileBaseName: 主 bundle 内 `Audio/` 目录下的音频文件名（不含扩展名）
    func play(audioFileBaseName: String) async {
        // 如果已经在播，先停掉
        if isPerforming { stop() }

        guard let url = Self.locateAudio(named: audioFileBaseName) else {
            print("❌ 找不到表演音频: \(audioFileBaseName).(m4a/wav/mp3)")
            return
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            print("❌ 表演音频加载失败: \(error)")
            return
        }
        player.delegate = self
        player.prepareToPlay()

        audioPlayer = player
        isPerforming = true
        queuedMessages.removeAll()

        // print("🎵 表演开始: \(audioFileBaseName) (\(String(format: "%.1f", player.duration))s)")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.playCompletion = cont
            player.play()
            // 歌曲若带 sidecar 口型曲线(<音频名>_mouth.json),交给上层驱动嘴形
            self.onPlaybackStarted?(player, MouthCurve.locate(forAudioBaseName: audioFileBaseName))
        }

        // 走到这里时 delegate 已清理状态
        // print("🎵 表演结束: \(audioFileBaseName)")
    }

    /// 强制终止（切角色 / 用户手动中断时调用）
    func stop() {
        let wasPerforming = isPerforming
        audioPlayer?.stop()
        audioPlayer = nil
        isPerforming = false
        if wasPerforming { onPlaybackEnded?() }
        // 如果有等待 play 返回的调用方，让它解开
        playCompletion?.resume()
        playCompletion = nil
    }

    // MARK: - 队列

    /// 表演期间把用户消息暂存起来
    /// - Returns: 是否成功入队（非表演状态返回 false）
    @discardableResult
    func queueMessage(_ text: String) -> Bool {
        guard isPerforming else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        queuedMessages.append(t)
        // print("📥 入队消息（当前 \(queuedMessages.count) 条）")
        return true
    }

    /// 取出并清空队列；多条消息用换行合并
    func flushQueue() -> String? {
        guard !queuedMessages.isEmpty else { return nil }
        let combined = queuedMessages.joined(separator: "\n")
        queuedMessages.removeAll()
        return combined
    }

    // MARK: - Helpers

    /// 依次尝试常见扩展名定位音频
    static func locateAudio(named baseName: String) -> URL? {
        let bundle = Bundle.main
        // 支持 Characters / Audio 两处，以及无子目录的 bundle 根
        for ext in ["m4a", "mp3", "wav", "aac", "caf"] {
            if let url = bundle.url(forResource: baseName, withExtension: ext, subdirectory: "Audio") {
                return url
            }
            if let url = bundle.url(forResource: baseName, withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

// MARK: - AVAudioPlayerDelegate

extension PerformanceService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPerforming = false
            self.audioPlayer = nil
            self.onPlaybackEnded?()
            let cont = self.playCompletion
            self.playCompletion = nil
            cont?.resume()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            print("⚠️ 表演音频解码错误: \(error?.localizedDescription ?? "unknown")")
            self.isPerforming = false
            self.audioPlayer = nil
            self.onPlaybackEnded?()
            let cont = self.playCompletion
            self.playCompletion = nil
            cont?.resume()
        }
    }
}
