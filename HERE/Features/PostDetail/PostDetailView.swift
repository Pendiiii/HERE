import SwiftUI

struct PostDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let post: NearbyPost
    @State private var replies: [Reply] = []
    @State private var replyText = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var safetyTarget: SafetyTarget?
    @State private var confirmsDeletion = false
    @FocusState private var isReplyFocused: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PostCard(post: post)
                Divider().padding(.bottom, 12)
                if isLoading { ProgressView().frame(maxWidth: .infinity).padding(30) }
                else if replies.isEmpty { Text("Noch keine Antworten. Antworte kurz und hilfreich.").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 28) }
                ForEach(replies) { reply in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            ProfileAvatarView(url: reply.avatarURL, size: 28)
                            Text(reply.displayName.replacingOccurrences(of: " · KI", with: "")).font(.caption.bold())
                            if reply.displayName.hasSuffix(" · KI") {
                                Text("KI").font(.caption2.bold()).foregroundStyle(Color.hereAccent)
                                    .accessibilityLabel("KI-generierte Antwort")
                            }
                            Text(HEREFormatting.age(since: reply.createdAt)).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Menu { Button("Melden", systemImage: "exclamationmark.bubble") { safetyTarget = .reply(reply) }; Button("Nutzer blockieren", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { safetyTarget = .reply(reply) } } label: { Image(systemName: "ellipsis") }
                        }
                        Text(reply.body)
                    }.padding(.vertical, 12)
                    Divider()
                }
            }.padding(.horizontal, 20)
        }
        .navigationTitle("Antworten")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if post.isOwn {
                        Button("Beitrag löschen", systemImage: "trash", role: .destructive) {
                            confirmsDeletion = true
                        }
                        Divider()
                    }
                    if !post.isOwn {
                        Button("Melden", systemImage: "exclamationmark.bubble") { safetyTarget = .post(post) }
                        Button("Nutzer blockieren", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { safetyTarget = .post(post) }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) { replyBar }
        .task { await loadReplies() }
        .sheet(item: $safetyTarget) { SafetyActionView(target: $0) }
        .alert("Beitrag löschen?", isPresented: $confirmsDeletion) {
            Button("Löschen", role: .destructive) { Task { await deletePost() } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Der Beitrag und alle Antworten verschwinden sofort.")
        }
        .alert("Fehler", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("OK") {} } message: { Text(errorMessage ?? "") }
    }

    private var replyBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Kurz antworten …", text: $replyText, axis: .vertical)
                .lineLimit(1...4).focused($isReplyFocused).padding(11).background(Color.hereCard, in: RoundedRectangle(cornerRadius: 16))
                .onChange(of: replyText) { _, value in if value.count > 280 { replyText = String(value.prefix(280)) } }
            Button { Task { await sendReply() } } label: { Image(systemName: "arrow.up").font(.headline).frame(width: 38, height: 38) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.circle).disabled(replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
    }

    private func loadReplies() async {
        defer { isLoading = false }
        do { replies = try await appModel.repository.fetchReplies(postID: post.id) }
        catch { errorMessage = "Antworten konnten nicht geladen werden." }
    }

    private func sendReply() async {
        isSending = true
        defer { isSending = false }
        do {
            let reply = try await appModel.repository.createReply(postID: post.id, body: replyText)
            replies.append(reply); replyText = ""; UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { errorMessage = (error as? LocalizedError)?.errorDescription ?? "Antwort konnte nicht gesendet werden." }
    }

    private func deletePost() async {
        do {
            try await appModel.deletePost(post)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Der Beitrag konnte nicht gelöscht werden."
        }
    }
}

enum SafetyTarget: Identifiable {
    case post(NearbyPost), reply(Reply)
    var id: UUID { switch self { case .post(let post): post.id; case .reply(let reply): reply.id } }
}
