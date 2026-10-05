import CoreLocation
import Foundation

enum PostCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case general, question, food, ride, activity, free, warning, campus, event

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "Allgemein"
        case .question: "Frage"
        case .food: "Essen"
        case .ride: "Fahrt"
        case .activity: "Aktivität"
        case .free: "Kostenlos"
        case .warning: "Hinweis"
        case .campus: "Campus"
        case .event: "Event"
        }
    }
    var symbolName: String {
        switch self {
        case .general: "bubble.left"
        case .question: "questionmark.circle"
        case .food: "fork.knife"
        case .ride: "car"
        case .activity: "figure.2"
        case .free: "gift"
        case .warning: "exclamationmark.triangle"
        case .campus: "building.columns"
        case .event: "ticket"
        }
    }
}

enum PostLifetime: Int, CaseIterable, Identifiable, Sendable {
    case thirtyMinutes = 30, oneHour = 60, threeHours = 180, sixHours = 360
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .thirtyMinutes: "30 Min."
        case .oneHour: "1 Stunde"
        case .threeHours: "3 Stunden"
        case .sixHours: "6 Stunden"
        }
    }
    var duration: TimeInterval { TimeInterval(rawValue * 60) }
}

enum SearchRadius: Int, CaseIterable, Identifiable, Sendable {
    case twoFifty = 250, fiveHundred = 500, oneKilometer = 1_000, threeKilometers = 3_000
    var id: Int { rawValue }
    var meters: Double { Double(rawValue) }
    var title: String { rawValue < 1_000 ? "\(rawValue) m" : "\(rawValue / 1_000) km" }
}

struct NearbyPost: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let authorID: UUID
    let displayName: String
    let body: String
    let category: PostCategory?
    let createdAt: Date
    let expiresAt: Date
    let approximateDistance: Int
    var replyCount: Int
    var isOwn: Bool = false
    var imageURLs: [URL] = []
    var avatarURL: URL?

    var isExpired: Bool { expiresAt <= Date() }
}

struct Reply: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let postID: UUID
    let authorID: UUID
    let displayName: String
    let body: String
    let createdAt: Date
    var avatarURL: URL? = nil
}

enum SupportTicketStatus: String, Codable, Sendable {
    case pending, open, closing, closed
}

enum SupportMessageSender: String, Codable, Sendable {
    case user, staff, system
}

struct SupportMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let sender: SupportMessageSender
    let body: String
    let staffName: String?
    let createdAt: Date
    var imageURLs: [URL] = []
}

struct SupportTicket: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let status: SupportTicketStatus
    let assignedStaffName: String?
    let createdAt: Date
    let messages: [SupportMessage]
}

enum ClanLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    case open, municipal, county, state, national

    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: "Offene Clans"
        case .municipal: "Kommunal"
        case .county: "Landkreis / Bezirk"
        case .state: "Bundesland"
        case .national: "Bundesweit"
        }
    }
    var clanTitle: String {
        switch self {
        case .open: "Offener Clan"
        case .municipal: "Kommunaler Clan"
        case .county: "Landkreis- / Bezirksclan"
        case .state: "Landesclan"
        case .national: "Bundesclan"
        }
    }
    var symbol: String {
        switch self {
        case .open: "person.3.fill"
        case .municipal: "building.2.fill"
        case .county: "map.fill"
        case .state: "map"
        case .national: "globe.europe.africa.fill"
        }
    }
    var placeholder: String {
        switch self {
        case .open: "Clanname, z. B. Nachtschwärmer"
        case .municipal: "Stadt oder Gemeinde, z. B. Berlin"
        case .county: "Landkreis oder Bezirk"
        case .state: "Bundesland, z. B. Bayern"
        case .national: "Clanname für Deutschland"
        }
    }
}

struct CityClanOverview: Codable, Hashable, Sendable {
    let clanID: UUID?
    let cityName: String?
    let clanLevel: ClanLevel
    let memberCount: Int
    let weeklyPoints: Int
    let weeklyRank: Int?
    let switchAvailableAt: Date?
    var iconURL: URL? = nil

    var hasJoined: Bool { clanID != nil && cityName != nil }
}

struct CityClanStanding: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let cityName: String
    let memberCount: Int
    let weeklyPoints: Int
    let weeklyRank: Int
    let clanLevel: ClanLevel
    var iconURL: URL? = nil
}

enum ReportReason: String, CaseIterable, Identifiable, Sendable {
    case spam = "Spam"
    case harassment = "Belästigung"
    case hate = "Hass"
    case sexual = "Sexuelle Inhalte"
    case dangerous = "Gefährliches Verhalten"
    case fraud = "Betrug"
    case personalInformation = "Persönliche Informationen"
    case other = "Sonstiges"
    var id: String { rawValue }
}

struct LocalIdentity: Codable, Sendable {
    var displayName: String

    static func loadOrCreate(defaults: UserDefaults = .standard) -> LocalIdentity {
        if let data = defaults.data(forKey: "localIdentity"),
           let identity = try? JSONDecoder().decode(LocalIdentity.self, from: data) { return identity }
        let adjectives = ["Quiet", "Blue", "Tiny", "Swift", "Warm", "Silver"]
        let animals = ["Fox", "Otter", "Falcon", "Badger", "Robin", "Panda"]
        let identity = LocalIdentity(
            displayName: "\(adjectives.randomElement()!)\(animals.randomElement()!)\(Int.random(in: 10...99))"
        )
        if let data = try? JSONEncoder().encode(identity) { defaults.set(data, forKey: "localIdentity") }
        return identity
    }
}
