//
//  MemoryInspectorScreen.swift
//  DigitalCompanionPhone
//
//  开发期调试用的记忆检查器：
//    - 列出所有已存档的角色（通过 Storage.listStoredPersonaIDs）
//    - 每行显示消息数 + 最后活跃时间
//    - 点开看详情（摘要 / 消息历史 / 最新 LLM suggestions）
//    - 提供"删单个 / 清全部"危险操作
//
//  现阶段只展示 A0.2 已有的数据（messages / memorySummary / suggestions）。
//  Phase A1 做完后把 Facts / Episodes / Bonds 区块接进详情页即可，不动主结构。
//

import SwiftUI
import CompanionCore

struct MemoryInspectorScreen: View {

    @Environment(PhoneAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [ChatSnapshot] = []
    @State private var isLoading = true
    @State private var confirmWipeAll = false

    var body: some View {
        NavigationStack {
            List {
                // 存储信息
                Section {
                    LabeledContent("后端") {
                        Text(storageBackendLabel).foregroundStyle(.secondary)
                    }
                    LabeledContent("已存档角色") {
                        Text("\(snapshots.count)").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("存储")
                }

                // 角色列表
                if snapshots.isEmpty && !isLoading {
                    Section {
                        Text("还没有任何对话记录")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("角色") {
                        ForEach(snapshots, id: \.personaID) { snapshot in
                            NavigationLink {
                                PersonaMemoryDetailScreen(snapshot: snapshot)
                            } label: {
                                personaRow(snapshot)
                            }
                        }
                    }
                }

                // 危险区
                if !snapshots.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            confirmWipeAll = true
                        } label: {
                            Label("清除所有角色的记录", systemImage: "trash")
                        }
                    } footer: {
                        Text("删除磁盘上所有角色的快照文件。仅本设备；iCloud 的其它设备不受影响。")
                    }
                }
            }
            .navigationTitle("记忆检查器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .confirmationDialog(
                "清除所有记录？",
                isPresented: $confirmWipeAll,
                titleVisibility: .visible
            ) {
                Button("确定清除", role: .destructive) {
                    Task {
                        await appModel.wipeAllHistory()
                        await reload()
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("会删除 \(snapshots.count) 个角色的全部对话历史，此操作无法撤销。")
            }
        }
    }

    // MARK: - 角色行

    private func personaRow(_ snapshot: ChatSnapshot) -> some View {
        HStack(spacing: 12) {
            // 头像
            if let persona = CharacterPersona.load(named: snapshot.personaID) {
                ChatAvatar(
                    kind: .character(name: persona.name, id: persona.id),
                    size: 40
                )
            } else {
                ChatAvatar(
                    kind: .character(name: "?", id: snapshot.personaID),
                    size: 40
                )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: snapshot.personaID))
                    .font(.body)
                HStack(spacing: 6) {
                    Text("\(snapshot.messages.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(ChatTimestampFormatter.format(snapshot.lastModified))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - 辅助

    private var storageBackendLabel: String {
        switch appModel.storageBackend {
        case .iCloud: return "iCloud"
        case .local:  return "本地"
        }
    }

    private func displayName(for personaID: String) -> String {
        CharacterPersona.load(named: personaID)?.name ?? personaID
    }

    // MARK: - 数据加载

    private func reload() async {
        isLoading = true
        let ids = (try? await appModel.storage.listStoredPersonaIDs()) ?? []
        var loaded: [ChatSnapshot] = []
        for id in ids {
            if let snap = try? await appModel.storage.loadChatSnapshot(personaID: id) {
                loaded.append(snap)
            }
        }
        // 按最后活跃时间倒序（最近活跃的在顶上）
        snapshots = loaded.sorted { $0.lastModified > $1.lastModified }
        isLoading = false
    }
}
