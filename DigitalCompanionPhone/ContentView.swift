//
//  ContentView.swift
//  DigitalCompanionPhone
//
//  app 根视图：NavigationStack 里放 ChatScreen；
//  首次启动没 API Key 时自动弹出 APIKeySetupScreen。
//

import SwiftUI
import CompanionCore

struct ContentView: View {

    @Environment(PhoneAppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        #if DEBUG
        if ScreenshotDemoData.isEnabled, ScreenshotDemoData.route == "profile" {
            UserPersonaEditor()
        } else if ScreenshotDemoData.isEnabled, ScreenshotDemoData.route == "memory" {
            ScreenshotMemoryDetailRoot()
        } else {
            standardContent(appModel: appModel)
        }
        #else
        standardContent(appModel: appModel)
        #endif
    }

    @ViewBuilder
    private func standardContent(appModel: PhoneAppModel) -> some View {
        @Bindable var appModel = appModel

        NavigationStack {
            ChatScreen()
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        PersonaMenu()
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            appModel.showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        }
        .sheet(isPresented: $appModel.showAPIKeySetup) {
            APIKeySetupScreen()
        }
        .sheet(isPresented: $appModel.showSettings) {
            SettingsScreen()
        }
        .onAppear {
            if !appModel.isAPIKeyConfigured {
                appModel.showAPIKeySetup = true
            }
        }
    }
}

#if DEBUG
private struct ScreenshotMemoryDetailRoot: View {
    @Environment(PhoneAppModel.self) private var appModel
    @State private var snapshot: ChatSnapshot?

    var body: some View {
        NavigationStack {
            if let snapshot {
                PersonaMemoryDetailScreen(snapshot: snapshot)
            } else {
                ProgressView("正在准备伙伴记忆…")
                    .task { await loadSnapshot() }
            }
        }
    }

    private func loadSnapshot() async {
        let personaID = ScreenshotDemoData.personaID ?? "oc"
        for _ in 0..<20 {
            if let loaded = try? await appModel.storage.loadChatSnapshot(personaID: personaID) {
                snapshot = loaded
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(PhoneAppModel())
}
