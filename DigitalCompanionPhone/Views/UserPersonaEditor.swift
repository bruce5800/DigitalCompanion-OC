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

    var body: some View {
        NavigationStack {
            Form {
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
            }
        }
    }

    private var hasChanges: Bool {
        name != appModel.userPersona.name || description != appModel.userPersona.description
    }

    private func save() {
        let newValue = UserPersona(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "旅行者" : name,
            description: description
        )
        appModel.updateUserPersona(newValue)
        dismiss()
    }
}
