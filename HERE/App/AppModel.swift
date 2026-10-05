import CoreLocation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppModel {
    var posts: [NearbyPost] = []
    var pendingPosts: [NearbyPost] = []
    var activityPosts: [NearbyPost] = []
    var selectedRadius: SearchRadius = .fiveHundred
    var isLoading = false
    var errorMessage: String?
    var isComposerPresented = false
    var selectedPost: NearbyPost?

    let locationService = LocationService()
    var identity: LocalIdentity
    var repository: any HERERepository

    init() {
        let identity = LocalIdentity.loadOrCreate()
        self.identity = identity
        let configuration = AppConfiguration.current
        repository = SupabaseRepository(configuration: configuration, fallbackIdentity: identity)
    }

    func start() async {
        do {
            let serverName = try await repository.fetchDisplayName()
            if serverName != identity.displayName {
                identity.displayName = serverName
                if let data = try? JSONEncoder().encode(identity) {
                    UserDefaults.standard.set(data, forKey: "localIdentity")
                }
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Dein Konto konnte nicht geladen werden."
        }
        locationService.requestWhenInUseAuthorization()
        if locationService.coordinate != nil { await refresh() }
    }

    func refresh() async {
        guard let coordinate = locationService.coordinate else { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let nearby = repository.fetchNearby(coordinate: coordinate, radius: selectedRadius.meters)
            async let own = repository.fetchActivity()
            let (newPosts, activity) = try await (nearby, own)
            posts = newPosts.filter { !$0.isExpired }
            activityPosts = activity.filter { !$0.isExpired }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Etwas ist schiefgelaufen."
        }
    }

    func changeRadius(_ radius: SearchRadius) async {
        selectedRadius = radius
        await refresh()
    }

    func monitorNearby() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(30))
                guard let coordinate = locationService.coordinate else { continue }
                let latest = try await repository.fetchNearby(coordinate: coordinate, radius: selectedRadius.meters)
                let visibleIDs = Set(posts.map(\.id)).union(pendingPosts.map(\.id))
                let unseen = latest.filter { !visibleIDs.contains($0.id) && !$0.isExpired }
                if !unseen.isEmpty {
                    pendingPosts = (unseen + pendingPosts).uniqued(by: \.id)
                }
                posts.removeAll { $0.isExpired }
            } catch is CancellationError {
                return
            } catch {
                // Background refresh failures stay quiet; explicit refresh still surfaces errors.
            }
        }
    }

    func createPost(body: String, category: PostCategory?, lifetime: PostLifetime, allowAIReplies: Bool, images: [Data] = []) async throws {
        guard let coordinate = locationService.coordinate else { throw RepositoryError.locationUnavailable }
        let post = try await repository.createPost(
            body: body,
            category: category,
            lifetime: lifetime,
            coordinate: coordinate,
            allowAIReplies: allowAIReplies,
            images: images
        )
        posts.insert(post, at: 0)
        activityPosts.insert(post, at: 0)
    }

    func block(_ post: NearbyPost) async throws {
        try await repository.block(userID: post.authorID)
        posts.removeAll { $0.authorID == post.authorID }
        pendingPosts.removeAll { $0.authorID == post.authorID }
    }

    func deletePost(_ post: NearbyPost) async throws {
        guard post.isOwn else { throw RepositoryError.unauthorized }
        try await repository.deletePost(id: post.id)
        posts.removeAll { $0.id == post.id }
        pendingPosts.removeAll { $0.id == post.id }
        activityPosts.removeAll { $0.id == post.id }
        selectedPost = nil
    }

    func deleteAccount() async throws {
        try await repository.deleteAccount()
        UserDefaults.standard.removeObject(forKey: "localIdentity")
        identity = LocalIdentity.loadOrCreate()
        repository = SupabaseRepository(configuration: .current, fallbackIdentity: identity)
        posts = []
        pendingPosts = []
        activityPosts = []
        selectedPost = nil
        UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
    }

    func updateDisplayName(_ name: String) async throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...24).contains(clean.count), clean.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            throw RepositoryError.server("Verwende 3–24 Buchstaben oder Zahlen.")
        }
        try await repository.updateDisplayName(clean)
        identity.displayName = clean
        if let data = try? JSONEncoder().encode(identity) { UserDefaults.standard.set(data, forKey: "localIdentity") }
    }

    func acceptPendingPosts() {
        posts = (pendingPosts + posts).uniqued(by: \.id)
        pendingPosts.removeAll()
    }
}
