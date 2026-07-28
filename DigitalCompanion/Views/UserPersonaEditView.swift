//
//  UserPersonaEditView.swift
//  DigitalCompanion
//
//  编辑用户侧 Persona：让角色以更恰当的方式称呼 / 对待你
//

import SwiftUI
import CompanionCore

struct UserPersonaEditView: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var draftName: String = ""
    @State private var draftDescription: String = ""
    @State private var draftAvatarID: String = AvatarRegistry.userAvatarID

    private let avatarColumns = [
        GridItem(.adaptive(minimum: 80), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: avatarColumns, spacing: 16) {
                        ForEach(Array(AvatarRegistry.userAvatarIDs.enumerated()), id: \.element) { index, id in
                            avatarOption(id: id, index: index)
                        }
                    }
                    .padding(.vertical, 6)
                } header: {
                    Text("选择头像")
                } footer: {
                    Text("头像均为原创生成，不使用现有 IP 角色素材。")
                        .font(.caption)
                }

                Section {
                    TextField("昵称（如：旅行者 / 小明）", text: $draftName)
                } header: {
                    Text("你希望角色如何称呼你")
                } footer: {
                    Text("角色在对话中用 {{user}} 引用的名字。")
                        .font(.caption)
                }

                Section {
                    TextEditor(text: $draftDescription)
                        .frame(minHeight: 120)
                } header: {
                    Text("关于你（可选）")
                } footer: {
                    Text("一段简短的自我介绍，会作为背景信息注入对话，让角色更好地回应你。例如：「一名 visionOS 开发者，喜欢深夜编程，养了一只橘猫。」")
                        .font(.caption)
                }
            }
            .navigationTitle("你的身份")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let trimmedName = draftName.trimmingCharacters(in: .whitespaces)
                        appModel.updateUserPersona(UserPersona(
                            name: trimmedName.isEmpty ? "旅行者" : trimmedName,
                            description: draftDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                            avatarID: draftAvatarID
                        ))
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftName = appModel.userPersona.name
                draftDescription = appModel.userPersona.description
                draftAvatarID = AvatarRegistry.resolvedUserAvatarID(appModel.userPersona.avatarID)
            }
        }
    }

    @ViewBuilder
    private func avatarOption(id: String, index: Int) -> some View {
        Button {
            draftAvatarID = id
        } label: {
            if let url = AvatarRegistry.fileURL(for: id),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 80, height: 80)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(draftAvatarID == id ? Color.accentColor : .clear, lineWidth: 4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if draftAvatarID == id {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用户头像 \(index + 1)")
        .accessibilityAddTraits(draftAvatarID == id ? .isSelected : [])
    }
}
