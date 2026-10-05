import SwiftUI

struct SupportChatView: View {
    @Environment(AppModel.self) private var appModel
    @State private var ticket: SupportTicket?
    @State private var draft = ""
    @State private var selectedImages: [Data] = []
    @State private var isLoading = true
    @State private var isSending = false
    @State private var confirmsClosing = false
    @State private var errorMessage: String?

    private var canWrite: Bool {
        ticket == nil || ticket?.status == .pending || ticket?.status == .open || ticket?.status == .closed
    }

    var body: some View {
        Group {
            if isLoading && ticket == nil {
                ProgressView("Support wird geladen")
            } else {
                chatContent
            }
        }
        .navigationTitle("Support")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let ticket, ticket.status == .pending || ticket.status == .open {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Beenden", role: .destructive) { confirmsClosing = true }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if canWrite {
                VStack(spacing: 2) {
                    MediaImagePicker(images: $selectedImages, maximumCount: 4, maximumDimension: 1600, title: "Bilder anhängen")
                        .padding(.horizontal)
                    composer
                }
                .background(.bar)
            }
        }
        .task {
            await refresh(showLoading: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await refresh(showLoading: false)
            }
        }
        .confirmationDialog("Support-Chat beenden?", isPresented: $confirmsClosing) {
            Button("Ticket beenden", role: .destructive) { Task { await closeTicket() } }
        } message: {
            Text("Der zugehörige Support Chat wird gelöscht. Der Verlauf bleibt für dich in der App sichtbar.")
        }
        .alert("Support nicht erreichbar", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var chatContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    statusHeader
                    if let ticket {
                        ForEach(ticket.messages) { message in
                            SupportMessageBubble(message: message)
                                .id(message.id)
                        }
                        if ticket.status == .closing {
                            Text("Das Ticket wird beendet.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if ticket.status == .closed {
                            Text("Dieses Ticket ist beendet. Du kannst unten einen neuen Chat starten.")
                                .font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 8)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: ticket?.messages.count) {
                if let last = ticket?.messages.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 6) {
            Image(systemName: ticket?.assignedStaffName == nil ? "person.2" : "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(Color.hereAccent)
            if let staffName = ticket?.assignedStaffName {
                Text("Du schreibst mit \(staffName)").font(.headline)
            } else if ticket?.status == .closed {
                Text("Ticket beendet").font(.headline)
            } else if ticket == nil {
                Text("Direkter Kontakt zum HERE Staff").font(.headline)
            } else {
                Text("Warte auf ein Staff-Mitglied").font(.headline)
            }
            Text("Deine Nachricht wird in einen privaten Supportchat übertragen. Standortdaten werden nicht gesendet.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(ticket == nil || ticket?.status == .closed ? "Wobei können wir helfen?" : "Nachricht", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            Button { Task { await send() } } label: {
                Image(systemName: "arrow.up")
                    .font(.headline.bold())
                    .frame(width: 38, height: 38)
                    .background(Color.hereAccent, in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(isSending || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedImages.isEmpty) || draft.count > 1500)
            .accessibilityLabel("Nachricht senden")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    @MainActor
    private func refresh(showLoading: Bool) async {
        if showLoading { isLoading = true }
        defer { isLoading = false }
        do {
            ticket = try await appModel.repository.fetchSupportTicket()
        } catch {
            if showLoading { errorMessage = supportError(error) }
        }
    }

    @MainActor
    private func send() async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty || !selectedImages.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            if let ticket, ticket.status == .pending || ticket.status == .open {
                try await appModel.repository.sendSupportMessage(ticketID: ticket.id, message: message.isEmpty ? "Bild" : message, images: selectedImages)
            } else {
                ticket = try await appModel.repository.openSupportTicket(message: message.isEmpty ? "Bild" : message, images: selectedImages)
            }
            draft = ""
            selectedImages = []
            await refresh(showLoading: false)
        } catch {
            errorMessage = supportError(error)
        }
    }

    @MainActor
    private func closeTicket() async {
        guard let ticket else { return }
        do {
            try await appModel.repository.closeSupportTicket(ticketID: ticket.id)
            await refresh(showLoading: false)
        } catch {
            errorMessage = supportError(error)
        }
    }

    private func supportError(_ error: Error) -> String {
        let text = (error as? LocalizedError)?.errorDescription ?? "Der Support-Chat ist gerade nicht erreichbar."
        if text.localizedCaseInsensitiveContains("support rate limit") {
            return "Du hast zu viele Nachrichten gesendet. Warte bitte kurz."
        }
        return text
    }
}

private struct SupportMessageBubble: View {
    let message: SupportMessage

    var body: some View {
        HStack {
            if message.sender == .user { Spacer(minLength: 48) }
            VStack(alignment: message.sender == .user ? .trailing : .leading, spacing: 4) {
                if message.sender == .staff {
                    Text(message.staffName ?? "HERE Staff")
                        .font(.caption.bold()).foregroundStyle(Color.hereAccent)
                }
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(message.sender == .user ? Color.hereAccent : Color.secondary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(message.sender == .user ? Color.white : Color.primary)
                if !message.imageURLs.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        ForEach(Array(message.imageURLs.enumerated()), id: \.offset) { _, url in
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else if phase.error != nil {
                                    Image(systemName: "photo").foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(width: 130, height: 130)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if message.sender != .user { Spacer(minLength: 48) }
        }
    }
}
