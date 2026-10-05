import CoreLocation
import Foundation

protocol HERERepository: Sendable {
    func fetchNearby(coordinate: CLLocationCoordinate2D, radius: Double) async throws -> [NearbyPost]
    func fetchActivity() async throws -> [NearbyPost]
    func createPost(body: String, category: PostCategory?, lifetime: PostLifetime, coordinate: CLLocationCoordinate2D, allowAIReplies: Bool, images: [Data]) async throws -> NearbyPost
    func fetchReplies(postID: UUID) async throws -> [Reply]
    func createReply(postID: UUID, body: String) async throws -> Reply
    func report(targetType: String, targetID: UUID, reason: ReportReason) async throws
    func block(userID: UUID) async throws
    func updateDisplayName(_ displayName: String) async throws
    func fetchDisplayName() async throws -> String
    func deletePost(id: UUID) async throws
    func fetchSupportTicket() async throws -> SupportTicket?
    func openSupportTicket(message: String, images: [Data]) async throws -> SupportTicket
    func sendSupportMessage(ticketID: UUID, message: String, images: [Data]) async throws
    func closeSupportTicket(ticketID: UUID) async throws
    func fetchCityClans() async throws -> [CityClanOverview]
    func fetchCityClanLeaderboard() async throws -> [CityClanStanding]
    func joinCityClan(level: ClanLevel, name: String) async throws -> CityClanOverview
    func fetchMyAvatar() async throws -> URL?
    func updateAvatar(image: Data) async throws -> URL
    func updateClanIcon(clanID: UUID, image: Data) async throws -> URL
    func deleteAccount() async throws
}


enum RepositoryError: LocalizedError {
    case invalidConfiguration, locationUnavailable, unauthorized, rateLimited, expired, muted, banned, server(String)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Der HERE-Server ist in dieser App-Version nicht konfiguriert."
        case .locationUnavailable: "Dein Standort ist noch nicht verfügbar. Prüfe die Standortfreigabe und versuche es erneut."
        case .unauthorized: "Deine Sitzung konnte nicht erneuert werden. Bitte versuche es später erneut."
        case .rateLimited: "Zu viele Beiträge in kurzer Zeit. Versuch es später erneut."
        case .expired: "Dieser Beitrag ist nicht mehr verfügbar."
        case .muted: "Dein Konto wurde vorübergehend stummgeschaltet."
        case .banned: "Dein Konto wurde gesperrt."
        case .server(let message): message
        }
    }
}
