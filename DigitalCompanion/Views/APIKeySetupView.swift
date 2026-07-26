//
//  APIKeySetupView.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/4/12.
//

import SwiftUI
import CompanionCore

/// API Key 设置界面，支持 Claude、OpenAI、DeepSeek 和 Fish Audio
struct APIKeySetupView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var claudeKey: String = ""
    @State private var openAIKey: String = ""
    @State private var deepSeekKey: String = ""
    @State private var fishAudioKey: String = ""
    @State private var fishAudioReferenceID: String = ""
    @State private var selectedProvider: LLMProvider = .claude
    @State private var selectedTTSEngine: TTSEngine = .fishAudio

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - LLM 设置
                Section("LLM 服务选择") {
                    Picker("默认服务", selection: $selectedProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Claude API Key") {
                    SecureField("sk-ant-...", text: $claudeKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Text("从 console.anthropic.com 获取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("OpenAI API Key") {
                    SecureField("sk-...", text: $openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Text("从 platform.openai.com 获取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DeepSeek API Key") {
                    SecureField("sk-...", text: $deepSeekKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                    Text("从 platform.deepseek.com 获取")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // MARK: - TTS 设置
                Section("TTS 语音引擎") {
                    Picker("语音引擎", selection: $selectedTTSEngine) {
                        ForEach(TTSEngine.allCases) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if selectedTTSEngine == .fishAudio {
                    Section("Fish Audio 设置") {
                        SecureField("API Key", text: $fishAudioKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                        Text("从 fish.audio 获取")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField("音色 ID（可选）", text: $fishAudioReferenceID)
                            .autocorrectionDisabled()
                        Text("在 fish.audio 搜索角色音色，复制 ID 粘贴到此处")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("保存") {
                        saveAll()
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(!canSave)
                }
            }
            .navigationTitle("API 设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear {
                loadExistingKeys()
            }
        }
    }

    private var canSave: Bool {
        let llmAccount = selectedProvider.keychainAccount
        let llmKey: String
        switch selectedProvider {
        case .claude: llmKey = claudeKey
        case .openAI: llmKey = openAIKey
        case .deepSeek: llmKey = deepSeekKey
        }
        let llmReady = (!llmKey.isEmpty && !llmKey.hasPrefix("••••"))
            || KeychainService.load(forAccount: llmAccount) != nil

        // Fish Audio Key 不是必须的（会 fallback 到 Apple TTS）
        return llmReady
    }

    private func loadExistingKeys() {
        if KeychainService.load(forAccount: KeychainService.claudeAPIKeyAccount) != nil {
            claudeKey = "••••••••已设置"
        }
        if KeychainService.load(forAccount: KeychainService.openAIAPIKeyAccount) != nil {
            openAIKey = "••••••••已设置"
        }
        if KeychainService.load(forAccount: KeychainService.deepSeekAPIKeyAccount) != nil {
            deepSeekKey = "••••••••已设置"
        }
        if KeychainService.load(forAccount: KeychainService.fishAudioAPIKeyAccount) != nil {
            fishAudioKey = "••••••••已设置"
        }
        fishAudioReferenceID = appModel.ttsService.fishAudioReferenceID
        selectedProvider = appModel.selectedProvider
        selectedTTSEngine = appModel.ttsService.engine
    }

    private func saveAll() {
        // 保存 LLM Keys
        if !claudeKey.isEmpty && !claudeKey.hasPrefix("••••") {
            _ = KeychainService.save(key: claudeKey, forAccount: KeychainService.claudeAPIKeyAccount)
        }
        if !openAIKey.isEmpty && !openAIKey.hasPrefix("••••") {
            _ = KeychainService.save(key: openAIKey, forAccount: KeychainService.openAIAPIKeyAccount)
        }
        if !deepSeekKey.isEmpty && !deepSeekKey.hasPrefix("••••") {
            _ = KeychainService.save(key: deepSeekKey, forAccount: KeychainService.deepSeekAPIKeyAccount)
        }

        // 保存 Fish Audio Key
        if !fishAudioKey.isEmpty && !fishAudioKey.hasPrefix("••••") {
            _ = KeychainService.save(key: fishAudioKey, forAccount: KeychainService.fishAudioAPIKeyAccount)
        }

        // 更新 AppModel
        appModel.selectedProvider = selectedProvider
        appModel.ttsService.engine = selectedTTSEngine
        appModel.ttsService.fishAudioReferenceID = fishAudioReferenceID

        dismiss()
    }
}
