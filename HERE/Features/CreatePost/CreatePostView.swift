import SwiftUI

struct CreatePostView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool
    @State private var bodyText = ""
    @State private var selectedImages: [Data] = []
    @State private var category: PostCategory?
    @State private var lifetime: PostLifetime = .oneHour
    @State private var allowAIReplies = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Was passiert gerade?", text: $bodyText, axis: .vertical)
                        .lineLimit(4...8)
                        .focused($isFocused)
                        .onChange(of: bodyText) { _, value in
                            if value.count > 280 { bodyText = String(value.prefix(280)) }
                        }
                    HStack { Spacer(); Text("\(bodyText.count)/280").font(.caption).foregroundStyle(bodyText.count > 260 ? .orange : .secondary) }
                }

                Section("Bilder · optional") {
                    MediaImagePicker(images: $selectedImages, maximumCount: 4, maximumDimension: 1600)
                }

                Section("Kategorie · optional") {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(PostCategory.allCases) { item in
                                Button { category = category == item ? nil : item } label: {
                                    Label(item.title, systemImage: item.symbolName)
                                        .font(.subheadline.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 8)
                                        .background(category == item ? Color.hereAccent.opacity(0.18) : Color.hereCard, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }.scrollIndicators(.hidden)
                }

                Section("Verschwindet nach") {
                    Picker("Ablaufzeit", selection: $lifetime) {
                        ForEach(PostLifetime.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                }

                Section {
                    Toggle("KI-Antworten erlauben", isOn: $allowAIReplies)
                } footer: {
                    Text("Wenn aktiviert, wird nur dein Beitragstext an Google Gemini gesendet. Dein Standort bleibt auf dem HERE-Server.")
                }

                Section {
                    Label("Dein genauer Standort wird nie öffentlich angezeigt.", systemImage: "hand.raised.fill")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Hier posten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Posten") { Task { await submit() } }
                        .fontWeight(.semibold).disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
            .overlay { if isSubmitting { ProgressView().padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .alert("Nicht gepostet", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onAppear { isFocused = true }
        }
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await appModel.createPost(body: bodyText, category: category, lifetime: lifetime,
                                          allowAIReplies: allowAIReplies, images: selectedImages)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Bitte versuche es erneut."
        }
    }
}
