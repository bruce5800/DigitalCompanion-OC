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

    var body: some View {
        NavigationStack {
            Form {
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
                            description: draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftName = appModel.userPersona.name
                draftDescription = appModel.userPersona.description
            }
        }
    }
}
