import AppIntents
import CampusGuardUI
import TagKit

// Siri, Shortcuts, Spotlight and the Action button: "Arm my bag", "Ring my bag".
// Each intent waits for the tag's confirmation, like the buttons in the app.

struct ArmBagIntent: AppIntent {
    static let title: LocalizedStringResource = "Protect my bag"
    static let description = IntentDescription("Switches your Campus Guard tag to Alert mode.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TagIntentRunner.run(.arm, success: "Your bag is protected.")
    }
}

struct DisarmBagIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop protecting my bag"
    static let description = IntentDescription("Switches your Campus Guard tag to Normal mode and stops its siren.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TagIntentRunner.run(.disarm, success: "Your tag is in Normal mode.")
    }
}

struct RingBagIntent: AppIntent {
    static let title: LocalizedStringResource = "Ring my bag"
    static let description = IntentDescription("Plays three short beeps on your tag so you can find it nearby.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await TagIntentRunner.run(.chirp, success: "Listen for three short beeps.")
    }
}

enum TagIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notSetUp
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSetUp: "Set up your tag in the Campus Guard app first."
        case .failed(let message): "\(message)"
        }
    }
}

@MainActor
enum TagIntentRunner {
    static func run(_ command: TagCommand, success: String) async throws -> some IntentResult & ProvidesDialog {
        let model = AppModel.shared
        guard model.isConfigured else { throw TagIntentError.notSetUp }
        model.link.start()
        switch await model.link.send(command) {
        case .confirmed, .sent:
            return .result(dialog: IntentDialog(stringLiteral: success))
        case .failed(let failure):
            throw TagIntentError.failed(model.failureText(failure, command))
        }
    }
}

struct CampusGuardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ArmBagIntent(), phrases: ["Protect my bag with \(.applicationName)", "Arm my bag in \(.applicationName)"],
                    shortTitle: "Protect bag", systemImageName: "checkmark.shield")
        AppShortcut(intent: DisarmBagIntent(), phrases: ["Disarm my bag in \(.applicationName)", "Stop protecting my bag with \(.applicationName)"],
                    shortTitle: "Disarm bag", systemImageName: "shield.slash")
        AppShortcut(intent: RingBagIntent(), phrases: ["Ring my bag with \(.applicationName)", "Find my bag with \(.applicationName)"],
                    shortTitle: "Ring bag", systemImageName: "speaker.wave.2")
    }
}
