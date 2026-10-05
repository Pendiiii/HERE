import PhotosUI
import SwiftUI
import UIKit

struct MediaImagePicker: View {
    @Binding var images: [Data]
    let maximumCount: Int
    let maximumDimension: CGFloat
    var title = "Fotos hinzufügen"

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PhotosPicker(selection: $selectedItems, maxSelectionCount: max(1, maximumCount - images.count), matching: .images) {
                    Label(title, systemImage: "photo.badge.plus")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(images.count >= maximumCount || isLoading)
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                Text("\(images.count)/\(maximumCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                            if let image = UIImage(data: data) {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 76, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            images.remove(at: index)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2.bold())
                                                .foregroundStyle(.white)
                                                .frame(width: 23, height: 23)
                                                .background(.black.opacity(0.68), in: Circle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(4)
                                        .accessibilityLabel("Bild entfernen")
                                    }
                            }
                        }
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
            }
        }
        .onChange(of: selectedItems) { _, items in
            Task { await loadImages(items) }
        }
    }

    @MainActor
    private func loadImages(_ items: [PhotosPickerItem]) async {
        isLoading = true
        defer { isLoading = false; selectedItems = [] }
        errorMessage = nil
        for item in items.prefix(max(0, maximumCount - images.count)) {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let optimized = Self.optimizedJPEG(data, maximumDimension: maximumDimension) else {
                    errorMessage = "Dieses Bild konnte nicht geöffnet werden."
                    continue
                }
                images.append(optimized)
            } catch {
                errorMessage = "Das Bild konnte nicht geladen werden. Versuch es bitte erneut."
            }
        }
    }

    @MainActor
    static func optimizedJPEG(_ data: Data, maximumDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        var targetDimension = maximumDimension
        var lastResult: Data?
        for _ in 0..<4 {
            let scale = min(1, targetDimension / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let renderer = UIGraphicsImageRenderer(size: size)
            for quality in [0.8, 0.65, 0.5, 0.38] {
                let result = renderer.jpegData(withCompressionQuality: quality) { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                lastResult = result
                if result.count <= 1_900_000 { return result }
            }
            targetDimension *= 0.75
        }
        return lastResult.flatMap { $0.count <= 2_000_000 ? $0 : nil }
    }
}

struct ProfileAvatarView: View {
    let url: URL?
    var size: CGFloat = 38

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.hereAccent.opacity(0.72))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.secondary.opacity(0.16), lineWidth: 1))
        .accessibilityLabel("Profilbild")
    }
}
