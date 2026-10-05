import SwiftUI

struct CityClansView: View {
    @Environment(AppModel.self) private var appModel
    @State private var memberships: [CityClanOverview] = []
    @State private var leaderboard: [CityClanStanding] = []
    @State private var selectedLevel: ClanLevel = .municipal
    @State private var clanName = ""
    @State private var clanIconImages: [Data] = []
    @State private var isSavingClanIcon = false
    @State private var isLoading = true
    @State private var isJoining = false
    @State private var errorMessage: String?

    private var overview: CityClanOverview? { memberships.first { $0.clanLevel == selectedLevel && $0.hasJoined } }

    private var isCurrentClan: Bool {
        guard let existing = overview?.cityName else { return false }
        return clanName.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(existing, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private var canChangeClan: Bool {
        guard let deadline = overview?.switchAvailableAt, !isCurrentClan else { return true }
        return Date() >= deadline
    }

    private var visibleLeaderboard: [CityClanStanding] {
        leaderboard.filter { $0.clanLevel == selectedLevel }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                introCard
                levelPicker
                clanCard
                leaderboardSection
                scoringNote
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Clans")
        .navigationBarTitleDisplayMode(.large)
        .refreshable { await refresh(showErrors: true) }
        .task {
            await refresh(showErrors: true)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(45))
                if !Task.isCancelled { await refresh(showErrors: false) }
            }
        }
        .onChange(of: selectedLevel) { _, level in
            clanName = memberships.first(where: { $0.clanLevel == level })?.cityName ?? ""
            clanIconImages = []
        }
        .alert("Clans", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "trophy.fill")
                    .font(.title2)
                    .foregroundStyle(Color.hereAccent)
                Spacer()
                Text("WÖCHENTLICH")
                    .font(.caption2.bold())
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
            }
            Text("Gemeinsam an die Spitze")
                .font(.title2.bold())
            Text("Tritt einem Clan auf der Ebene bei, die zu dir passt – und sammle mit Beiträgen und Antworten Punkte für die Wochenrangliste.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private var levelPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CLAN-EBENE")
                .font(.caption2.bold())
                .tracking(1.1)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ClanLevel.allCases) { level in
                        Button { selectedLevel = level } label: {
                            Label(level.title, systemImage: level.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 13)
                                .padding(.vertical, 10)
                                .foregroundStyle(selectedLevel == level ? .white : Color.primary)
                                .background(selectedLevel == level ? Color.hereAccent : Color(.secondarySystemGroupedBackground), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var clanCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(overview?.hasJoined == true ? "Dein Clan" : "Clan beitreten")
                    .font(.headline)
                Spacer()
                Image(systemName: selectedLevel.symbol)
                    .foregroundStyle(Color.hereAccent)
            }

            if let overview, overview.hasJoined {
                HStack(spacing: 12) {
                    AsyncImage(url: overview.iconURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                        else { Image(systemName: selectedLevel.symbol).foregroundStyle(Color.hereAccent) }
                    }
                    .frame(width: 58, height: 58)
                    .background(Color.hereAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 17))
                    .clipShape(RoundedRectangle(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(overview.cityName ?? "").font(.title3.bold())
                        Text(overview.clanLevel.clanTitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 0) {
                    clanMetric(value: overview.weeklyRank.map { "#\($0)" } ?? "–", label: "Platz")
                    Spacer(minLength: 8)
                    clanMetric(value: "\(overview.weeklyPoints)", label: "Punkte")
                    Spacer(minLength: 8)
                    clanMetric(value: "\(overview.memberCount)", label: "Mitglieder")
                }
                Rectangle().fill(Color.secondary.opacity(0.16)).frame(height: 1)
                MediaImagePicker(images: $clanIconImages, maximumCount: 1, maximumDimension: 512,
                                 title: "Clanbild auswählen")
                if !clanIconImages.isEmpty, let clanID = overview.clanID {
                    Button {
                        Task {
                            isSavingClanIcon = true
                            defer { isSavingClanIcon = false }
                            do {
                                _ = try await appModel.repository.updateClanIcon(clanID: clanID, image: clanIconImages[0])
                                clanIconImages = []
                                await refresh(showErrors: true)
                            } catch {
                                errorMessage = friendlyError(error)
                            }
                        }
                    } label: {
                        if isSavingClanIcon { ProgressView() }
                        else { Label("Clanbild speichern", systemImage: "checkmark.circle.fill") }
                    }
                    .disabled(isSavingClanIcon)
                }
            } else if isLoading {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField(selectedLevel.placeholder, text: $clanName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit { Task { await joinClan() } }
                .padding(13)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))

            Button { Task { await joinClan() } } label: {
                HStack {
                    if isJoining { ProgressView().tint(.white) }
                    else { Image(systemName: overview?.hasJoined == true ? "arrow.trianglehead.2.clockwise" : "plus") }
                    Text(overview?.hasJoined == true ? "Clan wechseln" : "Clan beitreten")
                }
                .font(.subheadline.bold())
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Color.hereAccent, in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(.white)
            }
            .disabled(isJoining || clanName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || !canChangeClan)

            if let deadline = overview?.switchAvailableAt, Date() < deadline {
                Text("Du kannst deinen Clan am \(deadline.formatted(date: .abbreviated, time: .omitted)) wieder wechseln.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if overview?.hasJoined == true {
                Text("Du kannst auf jeder Ebene einem Clan angehören. Erarbeitete Punkte bleiben beim Clan, für den sie gesammelt wurden.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Für offene und bundesweite Clans genügt ein eigener Clanname. Ortsangaben wählst du selbst; HERE erfasst dafür keinen Standort.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private var leaderboardSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedLevel.title)-Rangliste")
                        .font(.headline)
                    Text("Punkte seit Montag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chart.bar.xaxis")
                    .foregroundStyle(Color.hereAccent)
            }

            if visibleLeaderboard.isEmpty && !isLoading {
                Text("Noch keine Clans auf dieser Ebene. Sei der Erste!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(visibleLeaderboard.prefix(25)) { standing in
                    leaderboardRow(standing)
                }
            }
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22))
    }

    private var scoringNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.hereAccent)
            Text("3 Punkte pro Beitrag, 1 pro Antwort. Pro Person und Ebene zählen höchstens 15 Punkte am Tag. Gelöschte Inhalte verlieren ihre Punkte.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func clanMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func leaderboardRow(_ standing: CityClanStanding) -> some View {
        let isMine = standing.id == overview?.clanID
        return HStack(spacing: 12) {
            Text(standing.weeklyRank <= 3 ? ["①", "②", "③"][standing.weeklyRank - 1] : "#\(standing.weeklyRank)")
                .font(.subheadline.bold())
                .monospacedDigit()
                .foregroundStyle(standing.weeklyRank == 1 ? Color.hereAccent : Color.secondary)
                .frame(width: 34, alignment: .leading)
            AsyncImage(url: standing.iconURL) { phase in
                if let image = phase.image { image.resizable().scaledToFill() }
                else { Image(systemName: standing.clanLevel.symbol).foregroundStyle(Color.hereAccent) }
            }
            .frame(width: 36, height: 36)
            .background(Color.hereAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            .clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(standing.cityName)
                    .font(.subheadline.weight(isMine ? .bold : .medium))
                Text("\(standing.memberCount) \(standing.memberCount == 1 ? "Mitglied" : "Mitglieder")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(standing.weeklyPoints)")
                .font(.headline.monospacedDigit())
            Text("Pkt.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(isMine ? Color.hereAccent.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12))
    }

    @MainActor
    private func refresh(showErrors: Bool) async {
        do {
            async let clans = appModel.repository.fetchCityClans()
            async let scores = appModel.repository.fetchCityClanLeaderboard()
            let (loadedClans, loadedScores) = try await (clans, scores)
            memberships = loadedClans
            leaderboard = loadedScores
            if clanName.isEmpty, let currentName = loadedClans.first(where: { $0.clanLevel == selectedLevel })?.cityName {
                clanName = currentName
            }
            isLoading = false
        } catch {
            isLoading = false
            if showErrors { errorMessage = friendlyError(error) }
        }
    }

    @MainActor
    private func joinClan() async {
        let cleanName = clanName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...48).contains(cleanName.count) else {
            errorMessage = "Der Clanname muss 2 bis 48 Zeichen lang sein."
            return
        }
        isJoining = true
        defer { isJoining = false }
        do {
            let joined = try await appModel.repository.joinCityClan(level: selectedLevel, name: cleanName)
            memberships.removeAll { $0.clanLevel == selectedLevel }
            memberships.append(joined)
            await refresh(showErrors: true)
        } catch {
            errorMessage = friendlyError(error)
        }
    }

    private func friendlyError(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? "Die Clans konnten nicht geladen werden."
        if message.localizedCaseInsensitiveContains("clan switch cooldown active") {
            return "Du kannst deinen Clan nur alle 7 Tage wechseln."
        }
        if message.localizedCaseInsensitiveContains("invalid city name") {
            return "Bitte gib einen gültigen Clannamen ein."
        }
        return message
    }
}
