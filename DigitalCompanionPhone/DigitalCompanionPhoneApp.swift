//
//  DigitalCompanionPhoneApp.swift
//  DigitalCompanionPhone
//
//  iPhone 伴侣 app 的 @main 入口。
//  纯文字版 —— 不做 TTS / 3D / 场景识别，只聊天。
//  目的：
//    1. Phase A（长期记忆 / 主动性）的快速测试客户端
//    2. Phase D 正式产品化时的移动端基础
//

import SwiftUI

@main
struct DigitalCompanionPhoneApp: App {
    /// app 生命周期内唯一的状态实例
    @State private var appModel = PhoneAppModel()
    @AppStorage("uiLanguage") private var uiLanguage = "system"

    private var displayLocale: Locale {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--screenshot-language=en") {
            return Locale(identifier: "en")
        }
        #endif
        return uiLanguage == "system" ? .current : Locale(identifier: uiLanguage)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(\.locale, displayLocale)
        }
    }
}
