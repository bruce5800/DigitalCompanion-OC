//
//  DigitalCompanionApp.swift
//  DigitalCompanion
//
//  Created by 李卓伦 on 2026/3/28.
//

import SwiftUI

@main
struct DigitalCompanionApp: App {

    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
        }
        // 主窗口是纯 2D UI（聊天 + 设置），用 plain 避免 volumetric 跟头移动导致 sheet 抖动
        .windowStyle(.plain)
        .defaultSize(width: 600, height: 800)

        // 角色工坊:volumetric 窗,模型立在中间、控制面板 attachment 飘在旁边
        WindowGroup(id: "avatarStudio") {
            AvatarStudioView()
                .environment(appModel)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 1.1, height: 1.5, depth: 0.9, in: .meters)

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                    appModel.onImmersiveSpaceOpened()
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                    appModel.ttsService.stop()  // 角色不见了就别继续说话
                    appModel.clearModelCache()
                    appModel.onImmersiveSpaceClosed()  // 停掉场景扫描
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
