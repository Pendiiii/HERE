import CoreLocation
import Testing
@testable import HERE

struct HERELogicTests {
    @Test func expiryIsEnforced() {
        let expired = NearbyPost(id: UUID(), authorID: UUID(), displayName: "QuietFox82", body: "Test", category: nil,
                                 createdAt: .now.addingTimeInterval(-120), expiresAt: .now.addingTimeInterval(-1),
                                 approximateDistance: 50, replyCount: 0)
        #expect(expired.isExpired)
    }

    @Test func distanceIsPrivacyPreserving() {
        #expect(HEREFormatting.distance(42) == "unter 100 m")
        #expect(HEREFormatting.distance(187) == "ca. 150 m")
        #expect(HEREFormatting.distance(1_250) == "ca. 1.2 km")
    }

    @Test func postValidationTrimsAndRejectsInvalidContent() throws {
        #expect(try ModerationService().validated("  Kaffee?  ") == "Kaffee?")
        #expect(throws: PostValidationError.empty) { try ModerationService().validated("  ") }
        #expect(throws: PostValidationError.tooLong) { try ModerationService().validated(String(repeating: "a", count: 281)) }
        #expect(throws: PostValidationError.duplicate) { try ModerationService().validated("Hallo", recentBodies: ["hallo"]) }
    }

    @Test func slidingWindowRateLimit() {
        let now = Date()
        let limiter = SlidingWindowRateLimiter(limit: 5, window: 600)
        #expect(limiter.allows(Array(repeating: now, count: 4), now: now))
        #expect(!limiter.allows(Array(repeating: now, count: 5), now: now))
        #expect(limiter.allows(Array(repeating: now.addingTimeInterval(-601), count: 5), now: now))
    }

    @Test func backendSessionRefreshesBeforeExpiry() {
        let fresh = SupabaseAuthSession(accessToken: "a", refreshToken: "r", expiresAt: .now.addingTimeInterval(600))
        let expiring = SupabaseAuthSession(accessToken: "a", refreshToken: "r", expiresAt: .now.addingTimeInterval(30))
        #expect(!fresh.needsRefresh)
        #expect(expiring.needsRefresh)
    }

}
