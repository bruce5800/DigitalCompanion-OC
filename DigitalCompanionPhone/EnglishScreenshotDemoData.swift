#if DEBUG
import Foundation
import CompanionCore

/// English copy for isolated App Store screenshot data. Never touches real chats.
enum EnglishScreenshotDemoData {
    static var isEnabled: Bool {
        ScreenshotDemoData.isEnabled && (
            ProcessInfo.processInfo.arguments.contains("--screenshot-language=en")
            || UserDefaults.standard.string(forKey: "uiLanguage") == "en"
        )
    }

    static let userPersona = UserPersona(
        name: "Alex",
        description: "A product designer who enjoys photography and evening walks. Lately, I have been learning to cook.",
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

            let now = Date()
            let chat = ChatSnapshot(personaID: personaID, messages: messages, lastModified: now)
            let memory = memorySnapshot(for: personaID, now: now)
            do {
                try await storage.saveChatSnapshot(chat)
                try await storage.saveMemorySnapshot(memory)
            } catch {
                print("English screenshot data install failed: \(error)")
            }
        }
    }

    private static func memorySnapshot(for personaID: String, now: Date) -> MemorySnapshot {
        if personaID != "oc" {
            return MemorySnapshot(personaID: personaID, facts: [], episodes: [], bond: Bond(affection: 58, recentMood: "Looking forward to a quieter day"), lastReflected: now)
        }
        return MemorySnapshot(
            personaID: "oc",
            facts: [
                UserFact(category: .userInfo, content: "Alex is a product designer who enjoys photography and walking."),
                UserFact(category: .userInfo, content: "Alex has started learning to cook and wants to make a good beef stew."),
                UserFact(category: .relationship, content: "When Alex is tired, they prefer a quiet conversation to being rushed.")
            ],
            episodes: [
                Episode(title: "Talking through a tough workday", summary: "Alex felt discouraged by repeated project changes. We separated what could be controlled from what could not.", keywords: ["work", "stress"], startDate: now.addingTimeInterval(-12 * 86_400), endDate: now.addingTimeInterval(-12 * 86_400 + 3_600), emotionalTone: "Tense to relieved"),
                Episode(title: "A weekend photo walk", summary: "We planned to take the camera to the old streets near home this weekend.", keywords: ["photography", "weekend"], startDate: now.addingTimeInterval(-3 * 86_400), endDate: now.addingTimeInterval(-3 * 86_400 + 3_600), emotionalTone: "Hopeful")
            ],
            bond: Bond(affection: 76, recentMood: "A little tired after work, ready to unwind"),
            lastReflected: now
        )
    }
}
#endif
