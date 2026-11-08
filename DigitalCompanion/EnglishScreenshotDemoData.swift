#if DEBUG
import Foundation
import CompanionCore

/// English copy for isolated Vision Pro App Store screenshot data.
enum EnglishScreenshotDemoData {
    static var isEnabled: Bool {
        ScreenshotDemoData.isEnabled && (
            ProcessInfo.processInfo.arguments.contains("--screenshot-language=en")
            || UserDefaults.standard.string(forKey: "uiLanguage") == "en"
        )
    }

    static let userPersona = UserPersona(
        name: "Alex",
        description: "A product designer who enjoys photography and evening walks.",
        avatarID: "user-1"
    )

    static func install(into storage: any CompanionStorage) async {
        for personaID in ["oc", "sg", "xo"] {
            let messages: [ChatMessage]
            switch personaID {
            case "sg":
                messages = [
                    ChatMessage(role: .assistant, text: "You're here. Have a seat. You look tired today—take a breath first."),
                    ChatMessage(role: .user, text: "I have a product pitch tomorrow, and I don't feel ready."),
                    ChatMessage(role: .assistant, text: "Let's not judge yourself too quickly. We can list the three things that matter most and tackle them one at a time. You don't have to solve everything tonight.", animation: "thinking", suggestions: ["Help me make a list", "I'm worried about the opening", "Let me rest for a bit"])
                ]
            case "xo":
                messages = [
                    ChatMessage(role: .assistant, text: "There you are! I saved up a whole bag of little joys to share with you."),
                    ChatMessage(role: .user, text: "It rained today. I wanted to go out and take photos."),
                    ChatMessage(role: .assistant, text: "Then let's make it a rain-after edition! Once the sky clears, every reflection is a free filter. I'll find the angles; you take the shots.", animation: "happy", suggestions: ["Let's go this weekend", "Pick a photo theme", "Tell me a joke"])
                ]
            default:
                messages = [
                    ChatMessage(role: .assistant, text: "Welcome back. The tea is still warm. How was your day?"),
                    ChatMessage(role: .user, text: "Work was exhausting. I don't want to do anything now that I'm home."),
                    ChatMessage(role: .assistant, text: "Then don't push yourself any further tonight. Sit with me for a while and let the day settle. You don't have to feel better right away—rest is enough.", animation: "gentle", suggestions: ["Stay and chat with me", "A lot happened today", "I'd like some quiet"])
                ]
            }
            do {
                try await storage.saveChatSnapshot(ChatSnapshot(personaID: personaID, messages: messages, lastModified: Date()))
            } catch {
                print("English screenshot data install failed: \(error)")
            }
        }
    }
}
#endif
