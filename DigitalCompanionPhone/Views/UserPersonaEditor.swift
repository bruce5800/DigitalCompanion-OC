//
//  UserPersonaEditor.swift
//  DigitalCompanionPhone
//
//  编辑 {{user}}（角色如何称呼你 + 你想让她知道什么）。
//  保存后会触发当前角色对话重启（freshStart），让新的昵称/背景生效。
//

import SwiftUI
import CompanionCore

struct UserPersonaEditor: View {

    @Environment(PhoneAppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var avatarID: String = AvatarRegistry.userAvatarID

    private let avatarColumns = [
        GridItem(.adaptive(minimum: 68), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LazyVGrid(columns: avatarColumns, spacing: 12) {
                        ForEach(Array(AvatarRegistry.userAvatarIDs.enumerated()), id: \.element) { index, id in
                            avatarOption(id: id, index: index)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("选择头像")
                } footer: {
                    Text("头像均为原创生成，不使用现有 IP 角色素材。")
                }

                Section {
                    TextField("昵称", text: $name)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("角色怎么称呼你")
                } footer: {
                    Text("默认是「旅行者」。改完后当前角色会重新开场。")
                }

                Section {
                    TextEditor(text: $description)
                        .frame(minHeight: 120)
                } header: {
                    Text("你想让她知道什么（可选）")
                } footer: {
                    Text("几句话介绍你自己 —— 职业、爱好、最近在做什么。会作为「关于用户」注入到系统提示里。")
                }
            }
            .navigationTitle("用户 Persona")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .bold()
                        .disabled(!hasChanges)
                }
            }
            .onAppear {
                name = appModel.userPersona.name
                description = appModel.userPersona.description
                avatarID = AvatarRegistry.resolvedUserAvatarID(appModel.userPersona.avatarID)
            }
        }
    }

    private var hasChanges: Bool {
        name != appModel.userPersona.name
            || description != appModel.userPersona.description
            || avatarID != AvatarRegistry.resolvedUserAvatarID(appModel.userPersona.avatarID)
    }

    @ViewBuilder
    private func avatarOption(id: String, index: Int) -> some View {
        Button {
            avatarID = id
        } label: {
            if let url = AvatarRegistry.fileURL(for: id),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 68, height: 68)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .stroke(avatarID == id ? Color.accentColor : .clear, lineWidth: 4)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if avatarID == id {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("用户头像 \(index + 1)")
        .accessibilityAddTraits(avatarID == id ? .isSelected : [])
    }

    private func save() {
        let newValue = UserPersona(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "旅行者" : name,
            description: description,
            avatarID: avatarID
        )
        appModel.updateUserPersona(newValue)
        dismiss()
    }
}
