//
//  SettingsScreen.swift
//  DigitalCompanionPhone
//
//  设置页：LLM 服务商切换、API Key 入口、用户 Persona、清空对话、关于。
//

import SwiftUI
import CompanionCore

struct SettingsScreen: View {

    @Environment(PhoneAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var showUserPersona = false
    @State private var showAPIKeys = false
    @State private var showConfirmReset = false
    @State private var showMemoryInspector = false

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack {
            Form {
                Section("LLM 服务商") {
                    Picker("当前服务商", selection: $appModel.selectedProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    Button {
                        showAPIKeys = true
                    } label: {
                        HStack {
                            Text("API Key 配置")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Section("用户") {
                    Button {
                        showUserPersona = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(appModel.userPersona.name)
                                    .foregroundStyle(.primary)
                                if !appModel.userPersona.description.isEmpty {
                                    Text(appModel.userPersona.description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Section("对话") {
                    Button {
                        showMemoryInspector = true
                    } label: {
                        HStack {
                            Label("记忆检查器", systemImage: "brain.head.profile")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button(role: .destructive) {
                        showConfirmReset = true
                    } label: {
                        Label("清空当前角色对话", systemImage: "trash")
                    }
                }

                Section {
                    LabeledContent("存储后端") {
                        Text(storageBackendLabel)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(storageFooter)
                }

                Section("关于") {
                    LabeledContent("当前角色", value: appModel.currentPersonaName)
                    LabeledContent("消息数", value: "\(appModel.chatService.messages.count)")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showAPIKeys) {
                APIKeySetupScreen()
            }
            .sheet(isPresented: $showUserPersona) {
                UserPersonaEditor()
            }
            .sheet(isPresented: $showMemoryInspector) {
                MemoryInspectorScreen()
            }
            .confirmationDialog(
                "清空当前角色对话",
                isPresented: $showConfirmReset,
                titleVisibility: .visible
            ) {
                Button("确定清空", role: .destructive) {
                    appModel.resetCurrentChat()
                    dismiss()
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("会删除\(appModel.currentPersonaName)的对话记录，并重新发送开场白。其它角色的记录不受影响。")
            }
        }
    }

    // MARK: - 存储后端显示

    private var storageBackendLabel: String {
        switch appModel.storageBackend {
        case .iCloud: return "iCloud"
        case .local:  return "本地"
        }
    }

    private var storageFooter: String {
        switch appModel.storageBackend {
        case .iCloud:
            return "对话记录通过 iCloud 在你的所有设备间同步。"
        case .local:
            return "对话记录只保存在当前设备。要启用跨设备同步，请在 Xcode 项目里为 DigitalCompanionPhone target 打开 iCloud Documents capability。"
        }
    }
}
