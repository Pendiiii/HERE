import Foundation
import Testing
@testable import HERE

@MainActor
struct HEREViewModelTests {
    @Test func appStartsWithFiveHundredMeterRadius() {
        let model = AppModel()
        #expect(model.selectedRadius == .fiveHundred)
    }

    @Test func pendingPostsMergeWithoutDuplicates() {
        let model = AppModel()
        let post = NearbyPost(id: UUID(), authorID: UUID(), displayName: "TinyFalcon51", body: "Test", category: .general,
                              createdAt: .now, expiresAt: .now.addingTimeInterval(600), approximateDistance: 100, replyCount: 0)
        model.posts = [post]
        model.pendingPosts = [post]
        model.acceptPendingPosts()
        #expect(model.posts.count == 1)
        #expect(model.pendingPosts.isEmpty)
    }
}
