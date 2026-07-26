//
//  APIKeySetupScreen.swift
//  DigitalCompanionPhone
//
//  首次启动 / 用户主动设置时输入 API Key。
//  与 visionOS 的 APIKeySetupView 同源，但去掉 Fish Audio（iPhone 端不做 TTS）。
//

import SwiftUI
import CompanionCore

struct APIKeySetupScreen: View {

    @Environment(PhoneAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProvider: LLMProvider = .claude
    @State private var claudeKey = ""
    @State private var openAIKey = ""
    @State private var deepSeekKey = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("服务商", selection: $selectedProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                } header: {
                    Text("选择 LLM 服务商")
                } footer: {
                    Text("可以填多个的 Key，切换时不用重填。")
                }

                Section("Claude") {
                    SecureField("sk-ant-…", text: $claudeKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("OpenAI") {
                    SecureField("sk-…", text: $openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("DeepSeek") {
                    SecureField("sk-…", text: $deepSeekKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if saved {
                    Section {
                        Label("已保存", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("API Key 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                        .bold()
                }
            }
            .onAppear { loadExisting() }
            .onChange(of: selectedProvider) { _, new in
                appModel.selectedProvider = new
            }
        }
    }

    // MARK: - Logic

    private var canSave: Bool {
        !claudeKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
            || !deepSeekKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadExisting() {
        selectedProvider = appModel.selectedProvider
        // 只预填非空占位符标记，而不是真 key（安全起见不回显）
        if KeychainService.load(forAccount: KeychainService.claudeAPIKeyAccount) != nil {
            claudeKey = "••••••••"
        }
        if KeychainService.load(forAccount: KeychainService.openAIAPIKeyAccount) != nil {
            openAIKey = "••••••••"
        }
        if KeychainService.load(forAccount: KeychainService.deepSeekAPIKeyAccount) != nil {
            deepSeekKey = "••••••••"
        }
    }

    private func save() {
        let trimmed: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        let c = trimmed(claudeKey)
        if !c.isEmpty, c != "••••••••" {
            _ = KeychainService.save(key: c, forAccount: KeychainService.claudeAPIKeyAccount)
        }
        let o = trimmed(openAIKey)
        if !o.isEmpty, o != "••••••••" {
            _ = KeychainService.save(key: o, forAccount: KeychainService.openAIAPIKeyAccount)
        }
        let d = trimmed(deepSeekKey)
        if !d.isEmpty, d != "••••••••" {
            _ = KeychainService.save(key: d, forAccount: KeychainService.deepSeekAPIKeyAccount)
        }

        appModel.selectedProvider = selectedProvider
        saved = true
    }
}
