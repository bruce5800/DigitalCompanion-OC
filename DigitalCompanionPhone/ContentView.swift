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

#Preview {
    ContentView()
        .environment(PhoneAppModel())
}
