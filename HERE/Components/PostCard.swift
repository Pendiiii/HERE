import SwiftUI

struct PostCard: View {
    let post: NearbyPost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                ProfileAvatarView(url: post.avatarURL, size: 32)
                Text(post.displayName.replacingOccurrences(of: " · KI", with: ""))
                    .font(.caption.weight(.semibold))
                if post.displayName.hasSuffix(" · KI") {
                    Text("KI")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.hereAccent.opacity(0.15), in: Capsule())
                        .accessibilityLabel("KI-generierter Beitrag")
                }
            }
            .foregroundStyle(.secondary)

            Text(post.body)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !post.imageURLs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(Array(post.imageURLs.enumerated()), id: \.offset) { _, url in
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else if phase.error != nil {
                                    Image(systemName: "photo").foregroundStyle(.secondary)
                                } else {
                                    ProgressView()
                                }
                            }
                            .frame(width: 250, height: 175)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }

            Text(post.displayName.hasSuffix(" · KI")
                 ? "KI-Impuls · \(HEREFormatting.age(since: post.createdAt))"
                 : "\(HEREFormatting.distance(post.approximateDistance)) entfernt · \(HEREFormatting.age(since: post.createdAt))")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if post.category != nil || post.replyCount > 0 {
                HStack(spacing: 8) {
                    if let category = post.category {
                        Label(category.title, systemImage: category.symbolName)
                    }
                    if post.replyCount > 0 {
                        Text("·")
                        Text("\(post.replyCount) \(post.replyCount == 1 ? "Antwort" : "Antworten")")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 17)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(post.displayName), \(post.body), \(post.displayName.hasSuffix(" · KI") ? "KI-Impuls" : "\(HEREFormatting.distance(post.approximateDistance)) entfernt")")
    }
}
