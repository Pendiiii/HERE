import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = true
    @State private var isEditingName = false
    @State private var draftName = ""
    @State private var nameError: String?
    @State private var confirmsAccountDeletion = false
    @State private var isDeletingAccount = false
    @State private var avatarURL: URL?
    @State private var avatarImages: [Data] = []
    @State private var isSavingAvatar = false

    var body: some View {
        List {
            Section("Identität") {
                HStack(spacing: 14) {
                    ProfileAvatarView(url: avatarURL, size: 62)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Profilbild").font(.headline)
                        Text("Wird neben deinen Beiträgen angezeigt.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                MediaImagePicker(images: $avatarImages, maximumCount: 1, maximumDimension: 512,
                                 title: "Profilbild auswählen")
                if !avatarImages.isEmpty {
                    Button {
                        Task {
                            isSavingAvatar = true
                            defer { isSavingAvatar = false }
                            do {
                                avatarURL = try await appModel.repository.updateAvatar(image: avatarImages[0])
                                avatarImages = []
                            } catch {
                                nameError = (error as? LocalizedError)?.errorDescription ?? "Das Profilbild konnte nicht gespeichert werden."
                            }
                        }
                    } label: {
                        if isSavingAvatar { ProgressView() }
                        else { Label("Profilbild speichern", systemImage: "checkmark.circle.fill") }
                    }
                    .disabled(isSavingAvatar)
                }
                Button {
                    draftName = appModel.identity.displayName
                    isEditingName = true
                } label: {
                    LabeledContent("Anzeigename", value: appModel.identity.displayName)
                }.foregroundStyle(.primary)
                Text("Dein zufälliger Name schützt deine Identität. Für Blockierungen besitzt dein Konto intern eine stabile Kennung.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Privatsphäre") {
                Label("Nur beim Verwenden der App", systemImage: "location")
                Label("Keine Standortverläufe", systemImage: "figure.walk.motion")
                Label("Keine exakten Standorte im Feed", systemImage: "hand.raised")
                Text("KI-Accounts sind gekennzeichnet. Bei erlaubten KI-Antworten wird nur der Beitragstext an Google Gemini gesendet.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Hilfe") {
                NavigationLink {
                    SupportChatView()
                } label: {
                    Label("Support-Chat", systemImage: "message")
                }
            }
            Section {
                Button("Onboarding erneut anzeigen") { hasCompletedOnboarding = false }
            }
            Section {
                Button("Konto und Daten löschen", role: .destructive) {
                    confirmsAccountDeletion = true
                }
                .disabled(isDeletingAccount)
            }
            Section {
                Text("HERE 0.1 · Inhalte verschwinden automatisch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Einstellungen")
        .task {
            avatarURL = try? await appModel.repository.fetchMyAvatar()
        }
        .alert("Anzeigename", isPresented: $isEditingName) {
            TextField("Anzeigename", text: $draftName)
            Button("Speichern") {
                Task {
                    do { try await appModel.updateDisplayName(draftName) }
                    catch { nameError = (error as? LocalizedError)?.errorDescription ?? "Name konnte nicht gespeichert werden." }
                }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("3–24 Buchstaben oder Zahlen, ohne persönliche Angaben.") }
        .alert("Nicht gespeichert", isPresented: Binding(get: { nameError != nil }, set: { if !$0 { nameError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(nameError ?? "") }
        .confirmationDialog("Konto und Daten endgültig löschen?", isPresented: $confirmsAccountDeletion) {
            Button("Konto löschen", role: .destructive) {
                Task {
                    isDeletingAccount = true
                    defer { isDeletingAccount = false }
                    do { try await appModel.deleteAccount() }
                    catch { nameError = (error as? LocalizedError)?.errorDescription ?? "Konto konnte nicht gelöscht werden." }
                }
            }
        } message: {
            Text("Deine Beiträge, Antworten und das anonyme Konto werden dauerhaft entfernt.")
        }
    }
}
