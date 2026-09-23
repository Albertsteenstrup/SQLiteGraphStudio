import Foundation

public enum SpeechPlaybackStatus: Sendable, Equatable {
    case idle
    case installRequired
    case installing(String)
    case preparing(String)
    case generating
    case speaking
    case failed(String)

    public var displayText: String? {
        switch self {
        case .idle:
            return nil
        case .installRequired:
            return "Set up speech"
        case .installing(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Setting up speech" : message
        case .preparing(let message):
            return message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Preparing audio" : message
        case .generating:
            return "Preparing voice"
        case .speaking:
            return "Reading aloud"
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 96 else { return trimmed }
            return "\(trimmed.prefix(93))..."
        }
    }

    public var isBusy: Bool {
        switch self {
        case .installing, .preparing, .generating:
            true
        case .idle, .installRequired, .speaking, .failed:
            false
        }
    }

    public var requiresInstall: Bool {
        if case .installRequired = self {
            return true
        }
        return false
    }
}
