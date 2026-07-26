//
//  SpeechRecognitionService.swift
//  DigitalCompanion
//
//  语音识别（STT）服务。基于 Speech framework + AVAudioEngine 流式转写。
//  设计为 push-to-talk：外部（手势识别）控制 start/stop，期间 recognizedText
//  增量更新，ChatView 直接观察并同步到输入框。
//

import Foundation
import Speech
import AVFoundation

@MainActor
@Observable
class SpeechRecognitionService: NSObject {

    // MARK: - 对外状态

    /// 是否正在监听
    private(set) var isListening = false

    /// 实时识别文本（增量更新，观察者应绑定到 UI）
    private(set) var recognizedText = ""

    /// 错误信息（权限被拒 / 识别器不可用等）
    var errorMessage: String?

    // MARK: - 内部

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    // MARK: - 对外 API

    /// 开始监听。上一次的文本会被清空。
    /// 若权限未授予，会先请求；被拒 → 静默失败 + errorMessage 填充。
    func startListening() async {
        guard !isListening else { return }

        guard await requestAuthorization() else {
            errorMessage = "需要语音识别和麦克风权限"
            print("❌ 语音识别权限被拒")
            return
        }

        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "语音识别器不可用（中文包可能未下载）"
            print("❌ SFSpeechRecognizer 不可用")
            return
        }

        do {
            try startAudioEngine(recognizer: recognizer)
            recognizedText = ""
            errorMessage = nil
            isListening = true
            print("🎙 开始监听")
        } catch {
            errorMessage = "音频引擎启动失败: \(error.localizedDescription)"
            print("❌ 启动监听失败: \(error)")
            cleanup()
        }
    }

    /// 停止监听。recognizedText 保留最后一次识别结果供外部读取。
    func stopListening() {
        guard isListening else { return }
        cleanup()
        isListening = false
        print("🎙 停止监听，最终识别: \"\(recognizedText)\"")
    }

    // MARK: - 权限

    private func requestAuthorization() async -> Bool {
        // Speech 权限
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else { return false }

        // 麦克风权限（iOS 17+ / visionOS 用 AVAudioApplication）
        let micGranted: Bool = await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        return micGranted
    }

    // MARK: - 音频引擎

    private func startAudioEngine(recognizer: SFSpeechRecognizer) throws {
        // 音频会话：.playAndRecord 允许录音同时不禁用扬声器
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        // 保守地先卸一次（防止重复 install）
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.recognizedText = result.bestTranscription.formattedString
                }
                if error != nil {
                    // 非致命；stopListening 会统一清理
                    if let err = error {
                        print("⚠️ 识别 task error: \(err.localizedDescription)")
                    }
                }
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    private func cleanup() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}
