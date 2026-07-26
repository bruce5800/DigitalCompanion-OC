//
//  PersonaMenu.swift
//  DigitalCompanionPhone
//
//  导航栏中央的角色切换按钮：点一下弹菜单，选角色即切换。
//

import SwiftUI
import CompanionCore

struct PersonaMenu: View {

    @Environment(PhoneAppModel.self) private var appModel

    var body: some View {
        Menu {
            ForEach(appModel.availablePersonaIDs, id: \.self) { pid in
                Button {
                    appModel.switchCharacter(to: pid)
                } label: {
                    let isCurrent = appModel.currentPersona?.id == pid
                    let name = CharacterPersona.load(named: pid)?.name ?? pid
                    Label(
                        name,
                        systemImage: isCurrent ? "checkmark.circle.fill" : "person.circle"
                    )
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(appModel.currentPersonaName)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
