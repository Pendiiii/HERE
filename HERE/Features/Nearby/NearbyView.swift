import CoreLocation
import SwiftUI

struct NearbyView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                if !appModel.pendingPosts.isEmpty { newPostsButton }
                content
            }
            .padding(.horizontal, 20)
        }
        .refreshable { await appModel.refresh() }
        .safeAreaInset(edge: .bottom) {
            Button {
                appModel.isComposerPresented = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Label("Hier etwas posten", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .background(.bar)
            .accessibilityHint("Öffnet den schnellen Beitragseditor")
            .disabled(appModel.locationService.coordinate == nil)
        }
        .navigationBarHidden(true)
        .navigationDestination(item: $appModel.selectedPost) { post in
            PostDetailView(post: post)
        }
        .onChange(of: appModel.locationService.coordinate?.latitude) { _, _ in
            Task { await appModel.refresh() }
        }
        .alert("Nicht geladen", isPresented: Binding(get: { appModel.errorMessage != nil }, set: { if !$0 { appModel.errorMessage = nil } })) {
            Button("Erneut versuchen") { Task { await appModel.refresh() } }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text(appModel.errorMessage ?? "") }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HEREWordmark(width: 118)
                Spacer()
            }
            Text("Was passiert gerade um dich herum?")
                .font(.title2.weight(.semibold))
            Menu {
                ForEach(SearchRadius.allCases) { radius in
                    Button {
                        Task { await appModel.changeRadius(radius) }
                    } label: {
                        if radius == appModel.selectedRadius { Label(radius.title, systemImage: "checkmark") }
                        else { Text(radius.title) }
                    }
                }
            } label: {
                Label("Im Umkreis von ca. \(appModel.selectedRadius.title)", systemImage: "location.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    @ViewBuilder private var content: some View {
        if appModel.isLoading && appModel.posts.isEmpty {
            VStack(spacing: 16) { ProgressView(); Text("Wir schauen uns in deiner Nähe um …").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.top, 80)
        } else if appModel.locationService.authorizationStatus == .denied || appModel.locationService.authorizationStatus == .restricted {
            LocationDeniedView()
        } else if appModel.locationService.coordinate == nil {
            ContentUnavailableView("Standort wird ermittelt", systemImage: "location.circle",
                                   description: Text("Erlaube HERE den Standortzugriff, um Beiträge in deiner Nähe zu sehen."))
                .padding(.top, 50)
        } else if appModel.posts.isEmpty {
            ContentUnavailableView("Hier ist gerade nichts.", systemImage: "dot.radiowaves.left.and.right",
                                   description: Text("Sei die erste Person, die etwas postet."))
                .padding(.top, 50)
        } else {
            ForEach(appModel.posts) { post in
                Button { appModel.selectedPost = post } label: { PostCard(post: post) }
                    .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var newPostsButton: some View {
        Button { withAnimation { appModel.acceptPendingPosts() } } label: {
            Text("\(appModel.pendingPosts.count) neue Beiträge in deiner Nähe")
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(10)
        }
        .background(Color.hereAccent.opacity(0.12), in: Capsule())
        .padding(.bottom, 8)
    }
}

private struct LocationDeniedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Standort benötigt", systemImage: "location.slash")
        } description: {
            Text("HERE benötigt deinen Standort, um Beiträge in deiner Nähe zu finden. Deine exakte Position wird anderen niemals angezeigt.")
        } actions: {
            Button("Einstellungen öffnen") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.borderedProminent)
        }
        .padding(.top, 40)
    }
}
