import CoreLocation
import Foundation

actor SupabaseRepository: HERERepository {
    private let configuration: AppConfiguration
    private let fallbackIdentity: LocalIdentity
    private let session: URLSession
    private let sessionStore = SecureSessionStore()
    private var authSession: SupabaseAuthSession?
    private var currentDisplayName: String?
    private var cachedUserID: UUID?
    private var supportImageURLCache: [String: (url: URL, expiresAt: Date)] = [:]

    init(configuration: AppConfiguration, fallbackIdentity: LocalIdentity, session: URLSession = .shared) {
        self.configuration = configuration
        self.fallbackIdentity = fallbackIdentity
        self.session = session
    }

    func fetchNearby(coordinate: CLLocationCoordinate2D, radius: Double) async throws -> [NearbyPost] {
        let token = try await authenticatedToken()
        let payload: [String: Any] = ["latitude": coordinate.latitude, "longitude": coordinate.longitude, "radius_meters": radius]
        let data = try await request(path: "/rest/v1/rpc/get_nearby_posts", method: "POST", body: payload, token: token)
        return try Self.decoder.decode([NearbyPostDTO].self, from: data).map { dto in
            dto.model(imageURLs: dto.imagePaths.compactMap(publicMediaURL), avatarURL: publicMediaURL(dto.avatarPath))
        }
    }

    func fetchActivity() async throws -> [NearbyPost] {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_my_active_posts", method: "POST", body: [:], token: token)
        return try Self.decoder.decode([NearbyPostDTO].self, from: data).map { dto in
            dto.model(imageURLs: dto.imagePaths.compactMap(publicMediaURL), avatarURL: publicMediaURL(dto.avatarPath))
        }
    }

    func createPost(body: String, category: PostCategory?, lifetime: PostLifetime, coordinate: CLLocationCoordinate2D, allowAIReplies: Bool, images: [Data]) async throws -> NearbyPost {
        let clean = try ModerationService().validated(body)
        let token = try await authenticatedToken()
        let imagePaths = try await uploadImages(images, bucket: "here-public-media", subpath: "posts", token: token)
        let payload: [String: Any] = [
            "body_text": clean, "category_name": category?.rawValue ?? NSNull(),
            "lifetime_minutes": lifetime.rawValue, "latitude": coordinate.latitude, "longitude": coordinate.longitude,
            "allow_ai_reply": allowAIReplies, "requested_image_paths": imagePaths
        ]
        let data: Data
        do {
            data = try await request(path: "/rest/v1/rpc/create_nearby_post", method: "POST", body: payload, token: token)
        } catch {
            await deleteUploadedImages(imagePaths, bucket: "here-public-media", token: token)
            throw error
        }
        guard let dto = try Self.decoder.decode([NearbyPostDTO].self, from: data).first else {
            throw RepositoryError.server("Der Beitrag wurde nicht zurückgegeben.")
        }
        return dto.model(imageURLs: dto.imagePaths.compactMap(publicMediaURL), avatarURL: publicMediaURL(dto.avatarPath))
    }

    func fetchReplies(postID: UUID) async throws -> [Reply] {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_active_replies", method: "POST", body: ["target_post_id": postID.uuidString], token: token)
        return try Self.decoder.decode([ReplyDTO].self, from: data).map { $0.model(avatarURL: publicMediaURL($0.avatarPath)) }
    }

    func createReply(postID: UUID, body: String) async throws -> Reply {
        let clean = try ModerationService().validated(body)
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/create_reply", method: "POST", body: ["target_post_id": postID.uuidString, "body_text": clean], token: token)
        guard let dto = try Self.decoder.decode([ReplyDTO].self, from: data).first else {
            throw RepositoryError.server("Die Antwort wurde nicht zurückgegeben.")
        }
        return dto.model(avatarURL: publicMediaURL(dto.avatarPath))
    }

    func report(targetType: String, targetID: UUID, reason: ReportReason) async throws {
        let token = try await authenticatedToken()
        _ = try await request(path: "/rest/v1/rpc/create_report", method: "POST",
                              body: ["target_type_name": targetType, "target_uuid": targetID.uuidString,
                                     "reason_text": reason.rawValue], token: token)
    }

    func block(userID: UUID) async throws {
        let token = try await authenticatedToken()
        _ = try await request(path: "/rest/v1/blocks", method: "POST", body: ["blocked_id": userID.uuidString], token: token)
    }

    func updateDisplayName(_ displayName: String) async throws {
        let token = try await authenticatedToken()
        _ = try await request(path: "/rest/v1/rpc/ensure_profile", method: "POST", body: ["display_name": displayName], token: token)
        currentDisplayName = displayName
    }

    func fetchDisplayName() async throws -> String {
        if let currentDisplayName { return currentDisplayName }
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_my_display_name", method: "POST", body: [:], token: token)
        if let name = try JSONDecoder().decode(String?.self, from: data) {
            currentDisplayName = name
            return name
        }
        try await ensureProfile(token: token)
        currentDisplayName = fallbackIdentity.displayName
        return fallbackIdentity.displayName
    }

    func deletePost(id: UUID) async throws {
        let token = try await authenticatedToken()
        _ = try await request(path: "/rest/v1/rpc/delete_own_post", method: "POST",
                              body: ["target_post_id": id.uuidString], token: token)
    }

    func fetchSupportTicket() async throws -> SupportTicket? {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_support_ticket", method: "POST", body: [:], token: token)
        let rows = try Self.decoder.decode([SupportTicketRowDTO].self, from: data)
        guard let first = rows.first else { return nil }
        var messages: [SupportMessage] = []
        for row in rows {
            guard let message = row.message else { continue }
            let imageURLs = try await signedSupportURLs(row.imagePaths ?? [], token: token)
            messages.append(SupportMessage(id: message.id, sender: message.sender, body: message.body,
                                           staffName: message.staffName, createdAt: message.createdAt,
                                           imageURLs: imageURLs))
        }
        return SupportTicket(
            id: first.ticketID,
            status: first.ticketStatus,
            assignedStaffName: first.assignedStaffName,
            createdAt: first.ticketCreatedAt,
            messages: messages
        )
    }

    func openSupportTicket(message: String, images: [Data]) async throws -> SupportTicket {
        let clean = try Self.validSupportMessage(message)
        let token = try await authenticatedToken()
        let imagePaths = try await uploadImages(images, bucket: "here-support-media", subpath: "support", token: token)
        do {
            _ = try await request(path: "/rest/v1/rpc/open_support_ticket", method: "POST",
                                  body: ["first_message": clean, "requested_image_paths": imagePaths], token: token)
        } catch {
            await deleteUploadedImages(imagePaths, bucket: "here-support-media", token: token)
            throw error
        }
        guard let ticket = try await fetchSupportTicket() else {
            throw RepositoryError.server("Der Support-Chat konnte nicht geöffnet werden.")
        }
        return ticket
    }

    func sendSupportMessage(ticketID: UUID, message: String, images: [Data]) async throws {
        let clean = try Self.validSupportMessage(message)
        let token = try await authenticatedToken()
        let imagePaths = try await uploadImages(images, bucket: "here-support-media", subpath: "support", token: token)
        do {
            _ = try await request(path: "/rest/v1/rpc/send_support_message", method: "POST",
                                  body: ["target_ticket_id": ticketID.uuidString, "message_text": clean,
                                         "requested_image_paths": imagePaths], token: token)
        } catch {
            await deleteUploadedImages(imagePaths, bucket: "here-support-media", token: token)
            throw error
        }
    }

    func closeSupportTicket(ticketID: UUID) async throws {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/close_support_ticket", method: "POST",
                                     body: ["target_ticket_id": ticketID.uuidString], token: token)
        guard (try? JSONDecoder().decode(Bool.self, from: data)) == true else {
            throw RepositoryError.server("Das Support-Ticket ist bereits beendet.")
        }
    }

    func fetchCityClans() async throws -> [CityClanOverview] {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_my_city_clan", method: "POST", body: [:], token: token)
        return try Self.decoder.decode([CityClanOverviewDTO].self, from: data).map { $0.model(iconURL: publicMediaURL($0.iconPath)) }
    }

    func fetchCityClanLeaderboard() async throws -> [CityClanStanding] {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_city_clan_leaderboard", method: "POST", body: [:], token: token)
        return try Self.decoder.decode([CityClanStandingDTO].self, from: data).map { $0.model(iconURL: publicMediaURL($0.iconPath)) }
    }

    func joinCityClan(level: ClanLevel, name: String) async throws -> CityClanOverview {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/join_city_clan", method: "POST",
                                     body: ["requested_name": name, "requested_level": level.rawValue], token: token)
        guard let dto = try Self.decoder.decode([CityClanOverviewDTO].self, from: data).first else {
            throw RepositoryError.server("Der Beitritt zum Stadtclan wurde nicht bestätigt.")
        }
        return dto.model(iconURL: publicMediaURL(dto.iconPath))
    }

    func fetchMyAvatar() async throws -> URL? {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/get_my_avatar", method: "POST", body: [:], token: token)
        return publicMediaURL(try Self.decoder.decode(String?.self, from: data))
    }

    func updateAvatar(image: Data) async throws -> URL {
        let token = try await authenticatedToken()
        let userID = try await authenticatedUserID(token: token)
        let path = try await uploadImage(image, bucket: "here-public-media",
                                         path: "users/\(userID.uuidString.lowercased())/avatars/\(UUID().uuidString).jpg", token: token)
        do {
            _ = try await request(path: "/rest/v1/rpc/set_my_avatar", method: "POST", body: ["requested_path": path], token: token)
        } catch {
            await deleteUploadedImages([path], bucket: "here-public-media", token: token)
            throw error
        }
        guard let url = publicMediaURL(path) else { throw RepositoryError.server("Das Profilbild konnte nicht angezeigt werden.") }
        return url
    }

    func updateClanIcon(clanID: UUID, image: Data) async throws -> URL {
        let token = try await authenticatedToken()
        let userID = try await authenticatedUserID(token: token)
        let path = try await uploadImage(image, bucket: "here-public-media",
                                         path: "users/\(userID.uuidString.lowercased())/clans/\(clanID.uuidString.lowercased())/\(UUID().uuidString).jpg", token: token)
        do {
            _ = try await request(path: "/rest/v1/rpc/set_city_clan_icon", method: "POST",
                                  body: ["target_clan_id": clanID.uuidString, "requested_path": path], token: token)
        } catch {
            await deleteUploadedImages([path], bucket: "here-public-media", token: token)
            throw error
        }
        guard let url = publicMediaURL(path) else { throw RepositoryError.server("Das Clanbild konnte nicht angezeigt werden.") }
        return url
    }

    private func uploadImages(_ images: [Data], bucket: String, subpath: String, token: String) async throws -> [String] {
        guard images.count <= 4 else { throw RepositoryError.server("Du kannst höchstens vier Bilder anhängen.") }
        guard !images.isEmpty else { return [] }
        let userID = try await authenticatedUserID(token: token)
        var uploaded: [String] = []
        do {
            for image in images {
                let path = "users/\(userID.uuidString.lowercased())/\(subpath)/\(UUID().uuidString).jpg"
                uploaded.append(try await uploadImage(image, bucket: bucket, path: path, token: token))
            }
            return uploaded
        } catch {
            await deleteUploadedImages(uploaded, bucket: bucket, token: token)
            throw error
        }
    }

    private func uploadImage(_ image: Data, bucket: String, path: String, token: String) async throws -> String {
        guard image.count <= 2_000_000, configuration.supabaseURL != nil,
              let key = configuration.supabaseAnonKey, let url = storageObjectURL(bucket: bucket, path: path) else {
            throw RepositoryError.server("Das Bild ist zu groß oder der Speicher ist nicht verfügbar.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = image
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return path
    }

    private func deleteUploadedImages(_ paths: [String], bucket: String, token: String) async {
        guard !paths.isEmpty, let base = configuration.supabaseURL, let key = configuration.supabaseAnonKey else { return }
        var request = URLRequest(url: base.appending(path: "/storage/v1/object/\(bucket)"))
        request.httpMethod = "DELETE"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["prefixes": paths])
        _ = try? await session.data(for: request)
    }

    private func authenticatedUserID(token: String) async throws -> UUID {
        if let cachedUserID { return cachedUserID }
        guard let base = configuration.supabaseURL, let key = configuration.supabaseAnonKey else {
            throw RepositoryError.invalidConfiguration
        }
        var request = URLRequest(url: base.appending(path: "/auth/v1/user"))
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        cachedUserID = try Self.decoder.decode(AuthenticatedUserDTO.self, from: data).id
        guard let cachedUserID else { throw RepositoryError.unauthorized }
        return cachedUserID
    }

    private func signedSupportURLs(_ paths: [String], token: String) async throws -> [URL] {
        var urls: [URL] = []
        for path in paths {
            if let cached = supportImageURLCache[path], cached.expiresAt > Date().addingTimeInterval(60) {
                urls.append(cached.url)
                continue
            }
            let encodedPath = Self.encodedStoragePath(path)
            let data = try await request(path: "/storage/v1/object/sign/here-support-media/\(encodedPath)",
                                         method: "POST", body: ["expiresIn": 3600], token: token)
            let signed = try Self.decoder.decode(SignedStorageURLDTO.self, from: data).signedURL
            guard let url = signedStorageURL(signed) else { throw RepositoryError.server("Support-Bild konnte nicht geladen werden.") }
            supportImageURLCache[path] = (url, Date().addingTimeInterval(3300))
            urls.append(url)
        }
        return urls
    }

    private func publicMediaURL(_ path: String?) -> URL? {
        guard let path, let base = configuration.supabaseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path += "/storage/v1/object/public/here-public-media/" + Self.encodedStoragePath(path)
        return components.url
    }

    private func storageObjectURL(bucket: String, path: String) -> URL? {
        guard let base = configuration.supabaseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.path += "/storage/v1/object/\(bucket)/" + Self.encodedStoragePath(path)
        return components.url
    }

    private func signedStorageURL(_ path: String) -> URL? {
        guard let base = configuration.supabaseURL,
              let signed = URLComponents(string: path),
              var result = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        result.path += "/storage/v1" + signed.path
        result.query = signed.query
        return result.url
    }

    private static func encodedStoragePath(_ path: String) -> String {
        path.split(separator: "/").map { segment in
            String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
        }.joined(separator: "/")
    }

    private static func validSupportMessage(_ message: String) throws -> String {
        let clean = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...1500).contains(clean.count) else {
            throw RepositoryError.server("Nachrichten müssen zwischen 1 und 1500 Zeichen lang sein.")
        }
        return clean
    }

    func deleteAccount() async throws {
        let token = try await authenticatedToken()
        let data = try await request(path: "/rest/v1/rpc/delete_own_account", method: "POST", body: [:], token: token)
        guard (try? JSONDecoder().decode(Bool.self, from: data)) == true else {
            throw RepositoryError.server("Das Konto konnte nicht gelöscht werden.")
        }
        sessionStore.clear()
        authSession = nil
        currentDisplayName = nil
        cachedUserID = nil
    }

    private func authenticatedToken() async throws -> String {
        if authSession == nil { authSession = try sessionStore.load() }
        if let authSession {
            let token: String
            if authSession.needsRefresh {
                // Keep the device identity on network and refresh errors.
                token = try await refresh(using: authSession.refreshToken).accessToken
            } else {
                token = authSession.accessToken
            }
            return self.authSession?.accessToken ?? token
        }
        return try await createAnonymousSession().accessToken
    }

    private func createAnonymousSession() async throws -> SupabaseAuthSession {
        guard let base = configuration.supabaseURL, let key = configuration.supabaseAnonKey else { throw RepositoryError.invalidConfiguration }
        var request = URLRequest(url: base.appending(path: "/auth/v1/signup"))
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        let newSession = auth.session
        try sessionStore.save(newSession)
        authSession = newSession
        try await ensureProfile(token: newSession.accessToken)
        currentDisplayName = fallbackIdentity.displayName
        return newSession
    }

    private func refresh(using refreshToken: String) async throws -> SupabaseAuthSession {
        guard let base = configuration.supabaseURL, let key = configuration.supabaseAnonKey else { throw RepositoryError.invalidConfiguration }
        var components = URLComponents(url: base.appending(path: "/auth/v1/token"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let url = components?.url else { throw RepositoryError.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        let refreshed = try JSONDecoder().decode(AuthResponse.self, from: data).session
        try sessionStore.save(refreshed)
        authSession = refreshed
        return refreshed
    }

    private func ensureProfile(token: String) async throws {
        _ = try await request(path: "/rest/v1/rpc/ensure_profile", method: "POST", body: ["display_name": fallbackIdentity.displayName], token: token)
    }

    private func request(
        path: String,
        method: String,
        body: [String: Any],
        token: String,
        extraHeaders: [String: String] = [:],
        canRecoverAuthentication: Bool = true
    ) async throws -> Data {
        guard let base = configuration.supabaseURL, let key = configuration.supabaseAnonKey else { throw RepositoryError.invalidConfiguration }
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        extraHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, canRecoverAuthentication {
            let recoveredToken = try await recoverAuthentication()
            return try await self.request(path: path, method: method, body: body, token: recoveredToken,
                                          extraHeaders: extraHeaders, canRecoverAuthentication: false)
        }
        try Self.validate(response: response, data: data)
        return data
    }

    private func recoverAuthentication() async throws -> String {
        if let stored = try authSession ?? sessionStore.load() {
            return try await refresh(using: stored.refreshToken).accessToken
        }
        throw RepositoryError.unauthorized
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw RepositoryError.server("Keine Serverantwort.") }
        guard 200..<300 ~= response.statusCode else {
            if response.statusCode == 401 { throw RepositoryError.unauthorized }
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).message) ?? "Serverfehler (\(response.statusCode))."
            if message.localizedCaseInsensitiveContains("account muted") { throw RepositoryError.muted }
            if message.localizedCaseInsensitiveContains("account banned") { throw RepositoryError.banned }
            throw RepositoryError.server(message)
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct AuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }

    var session: SupabaseAuthSession {
        SupabaseAuthSession(accessToken: accessToken, refreshToken: refreshToken,
                            expiresAt: Date().addingTimeInterval(expiresIn))
    }
}
private struct AuthenticatedUserDTO: Decodable { let id: UUID }
private struct SignedStorageURLDTO: Decodable { let signedURL: String }
private struct ServerError: Decodable { let message: String }

private struct NearbyPostDTO: Decodable {
    let id, authorID: UUID
    let displayName, body: String
    let category: PostCategory?
    let createdAt, expiresAt: Date
    let approximateDistance, replyCount: Int
    let isOwn: Bool
    let imagePaths: [String]
    let avatarPath: String?
    enum CodingKeys: String, CodingKey {
        case id, body, category
        case authorID = "author_id", displayName = "display_name", createdAt = "created_at", expiresAt = "expires_at"
        case approximateDistance = "approximate_distance", replyCount = "reply_count"
        case isOwn = "is_own"
        case imagePaths = "image_paths", avatarPath = "avatar_path"
    }
    func model(imageURLs: [URL], avatarURL: URL?) -> NearbyPost {
        NearbyPost(id: id, authorID: authorID, displayName: displayName, body: body, category: category,
                   createdAt: createdAt, expiresAt: expiresAt, approximateDistance: approximateDistance,
                   replyCount: replyCount, isOwn: isOwn, imageURLs: imageURLs, avatarURL: avatarURL)
    }
}

private struct ReplyDTO: Decodable {
    let id, postID, authorID: UUID
    let displayName, body: String
    let createdAt: Date
    let avatarPath: String?
    enum CodingKeys: String, CodingKey { case id, body; case postID = "post_id", authorID = "author_id", displayName = "display_name", createdAt = "created_at", avatarPath = "avatar_path" }
    func model(avatarURL: URL?) -> Reply { Reply(id: id, postID: postID, authorID: authorID, displayName: displayName, body: body, createdAt: createdAt, avatarURL: avatarURL) }
}

private struct SupportTicketRowDTO: Decodable {
    let ticketID: UUID
    let ticketStatus: SupportTicketStatus
    let assignedStaffName: String?
    let ticketCreatedAt: Date
    let messageID: UUID?
    let messageSender: SupportMessageSender?
    let messageBody: String?
    let messageStaffName: String?
    let messageCreatedAt: Date?
    let imagePaths: [String]?

    enum CodingKeys: String, CodingKey {
        case ticketID = "ticket_id", ticketStatus = "ticket_status"
        case assignedStaffName = "assigned_staff_name", ticketCreatedAt = "ticket_created_at"
        case messageID = "message_id", messageSender = "message_sender", messageBody = "message_body"
        case messageStaffName = "message_staff_name", messageCreatedAt = "message_created_at"
        case imagePaths = "image_paths"
    }

    var message: SupportMessage? {
        guard let messageID, let messageSender, let messageBody, let messageCreatedAt else { return nil }
        return SupportMessage(id: messageID, sender: messageSender, body: messageBody,
                              staffName: messageStaffName, createdAt: messageCreatedAt)
    }
}

private struct CityClanOverviewDTO: Decodable {
    let clanID: UUID?
    let cityName: String?
    let clanLevel: ClanLevel
    let memberCount: Int
    let weeklyPoints: Int
    let weeklyRank: Int?
    let switchAvailableAt: Date?
    let iconPath: String?

    enum CodingKeys: String, CodingKey {
        case clanID = "clan_id", cityName = "city_name", memberCount = "member_count"
        case weeklyPoints = "weekly_points", weeklyRank = "weekly_rank", switchAvailableAt = "switch_available_at"
        case clanLevel = "clan_level"
        case iconPath = "icon_path"
    }

    func model(iconURL: URL?) -> CityClanOverview {
        CityClanOverview(clanID: clanID, cityName: cityName, clanLevel: clanLevel, memberCount: memberCount,
                         weeklyPoints: weeklyPoints, weeklyRank: weeklyRank, switchAvailableAt: switchAvailableAt,
                         iconURL: iconURL)
    }
}

private struct CityClanStandingDTO: Decodable {
    let clanID: UUID
    let cityName: String
    let memberCount: Int
    let weeklyPoints: Int
    let weeklyRank: Int
    let clanLevel: ClanLevel
    let iconPath: String?

    enum CodingKeys: String, CodingKey {
        case cityName = "city_name", memberCount = "member_count"
        case weeklyPoints = "weekly_points", weeklyRank = "weekly_rank"
        case clanID = "clan_id"
        case clanLevel = "clan_level"
        case iconPath = "icon_path"
    }

    func model(iconURL: URL?) -> CityClanStanding {
    CityClanStanding(id: clanID, cityName: cityName, memberCount: memberCount,
                     weeklyPoints: weeklyPoints, weeklyRank: weeklyRank,
                     clanLevel: clanLevel, iconURL: iconURL)
    }
}
