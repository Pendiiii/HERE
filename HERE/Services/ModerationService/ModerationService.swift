import Foundation

enum PostValidationError: LocalizedError, Equatable {
    case empty, tooLong, disallowedContent, duplicate
    var errorDescription: String? {
        switch self {
        case .empty: "Schreib kurz, was gerade passiert."
        case .tooLong: "Dein Beitrag darf höchstens 280 Zeichen lang sein."
        case .disallowedContent: "Dieser Inhalt kann nicht veröffentlicht werden."
        case .duplicate: "Diesen Inhalt hast du gerade schon gepostet."
        }
    }
}

struct ModerationService: Sendable {
    private let blockedTerms = ["heil hitler", "nazi", "kill yourself"]

    func validated(_ input: String, recentBodies: [String] = []) throws -> String {
        let body = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw PostValidationError.empty }
        guard body.count <= 280 else { throw PostValidationError.tooLong }
        let normalized = body.lowercased()
        guard !blockedTerms.contains(where: normalized.contains) else { throw PostValidationError.disallowedContent }
        guard !recentBodies.contains(where: { $0.caseInsensitiveCompare(body) == .orderedSame }) else {
            throw PostValidationError.duplicate
        }
        return body
    }
}

struct SlidingWindowRateLimiter: Sendable {
    let limit: Int
    let window: TimeInterval

    func allows(_ timestamps: [Date], now: Date = Date()) -> Bool {
        timestamps.filter { now.timeIntervalSince($0) < window }.count < limit
    }
}
