import SwiftUI

struct ActivityView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.activityPosts.isEmpty {
                ContentUnavailableView("Noch keine Aktivität", systemImage: "clock",
                                       description: Text("Deine aktiven Beiträge und Beteiligungen erscheinen hier – nur solange sie verfügbar sind."))
            } else {
                List(appModel.activityPosts) { post in
                    Button { appModel.selectedPost = post } label: { PostCard(post: post) }
                        .buttonStyle(.plain)
                }.listStyle(.plain)
            }
        }
        .navigationTitle("Aktivität")
        .refreshable { await appModel.refresh() }
        .navigationDestination(item: Binding(get: { appModel.selectedPost }, set: { appModel.selectedPost = $0 })) { PostDetailView(post: $0) }
    }
}
