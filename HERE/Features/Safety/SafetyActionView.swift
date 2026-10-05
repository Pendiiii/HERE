import SwiftUI

struct SafetyActionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    let target: SafetyTarget
    @State private var isWorking = false
    @State private var confirmation: String?
    @State private var alertTitle = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Melden") {
                    ForEach(ReportReason.allCases) { reason in
                        Button(reason.rawValue) { Task { await report(reason) } }
                    }
                }
                Section {
                    Button("Nutzer blockieren", role: .destructive) { Task { await block() } }
                } footer: {
                    Text("Alle Inhalte dieser Person werden sofort ausgeblendet. Die Person wird nicht benachrichtigt.")
                }
            }
            .navigationTitle("Sicherheit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
            .disabled(isWorking)
            .overlay { if isWorking { ProgressView() } }
            .alert(alertTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil; dismiss() } })) {
                Button("OK") {}
            } message: { Text(confirmation ?? "") }
        }
    }

    private var metadata: (type: String, id: UUID, authorID: UUID) {
        switch target {
        case .post(let post): ("post", post.id, post.authorID)
        case .reply(let reply): ("reply", reply.id, reply.authorID)
        }
    }

    private func report(_ reason: ReportReason) async {
        isWorking = true; defer { isWorking = false }
        do {
            try await appModel.repository.report(targetType: metadata.type, targetID: metadata.id, reason: reason)
            alertTitle = "Danke"
            confirmation = "Deine Meldung wurde vertraulich übermittelt."
        } catch {
            alertTitle = "Meldung nicht gesendet"
            confirmation = reportErrorMessage(error)
        }
    }

    private func block() async {
        isWorking = true; defer { isWorking = false }
        do {
            if case .post(let post) = target { try await appModel.block(post) }
            else { try await appModel.repository.block(userID: metadata.authorID) }
            alertTitle = "Blockiert"
            confirmation = "Die Person wurde blockiert."
        } catch {
            alertTitle = "Blockieren fehlgeschlagen"
            confirmation = (error as? LocalizedError)?.errorDescription ?? "Blockieren war gerade nicht möglich."
        }
    }

    private func reportErrorMessage(_ error: Error) -> String {
        if case RepositoryError.server(let message) = error {
            switch message {
            case "cannot report own content": return "Eigene Inhalte kannst du nicht melden."
            case "target unavailable": return "Dieser Inhalt ist nicht mehr verfügbar."
            case "report rate limit exceeded": return "Du hast zu viele Meldungen gesendet. Versuche es in einer Stunde erneut."
            default: return message
            }
        } else {
            return (error as? LocalizedError)?.errorDescription ?? "Die Meldung konnte gerade nicht übermittelt werden."
        }
    }
}
