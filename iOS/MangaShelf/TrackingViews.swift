import SwiftUI
import UIKit
import ReaderCore

struct TrackingHubView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject private var tracking = TrackingModel.shared
    @State private var trackingFAQ = false
    @State private var syncFAQ = false
    var body: some View {
        TachiSettingsPage(title: L10n.string("Tracking")) {
            TachiSectionTitle(L10n.string("Tracking services"))
            ForEach(TrackingService.allCases) { service in
                TachiNavigationRow(title: service.name, subtitle: tracking.account(service)?.viewer.name ?? L10n.string("Sign in"), symbol: "arrow.triangle.2.circlepath") {
                    TrackingAccountView(service: service)
                }
            }
            Text(L10n.string("Link a manga from its details to send completed chapter progress. Linking and successful delivery are shown separately."))
                .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
            TachiSectionTitle(L10n.string("Other services"))
            ForEach(["Bangumi", "MangaUpdates", "MangaBaka", "Komga", "Kavita", "Suwayomi"], id: \.self) { name in
                HStack {
                    Text(name).shelfFont(.body)
                    Spacer()
                    Text(L10n.string("Not connected")).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                }.padding(.horizontal, 18).frame(minHeight: 48)
            }
            Text(L10n.string("These additional services do not have an implemented account adapter in this version."))
                .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).padding(18)
            TachiSectionTitle(L10n.string("Frequently asked questions"))
            DisclosureGroup(L10n.string("What is tracking?"), isExpanded: $trackingFAQ) {
                Text(L10n.string("Tracking sends chapter counts to your chosen service after you explicitly match a manga. Only completed integer chapters count automatically; duplicate copies and fractional chapters do not inflate progress, and gaps stop automatic advancement."))
                    .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(.vertical, 12)
            }.padding(18)
            DisclosureGroup(L10n.string("How is tracking different from sync?"), isExpanded: $syncFAQ) {
                Text(L10n.string("Tracking updates a service's manga list. Device sync moves library data between your devices. Tracking does not upload chapter images or your library backup."))
                    .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(.vertical, 12)
            }.padding(18)
            if !tracking.state.deliveries.isEmpty {
                TachiNavigationRow(title: L10n.string("Tracking updates"), symbol: "arrow.up.circle") { TrackingOutboxView() }
            }
        }.task { await tracking.start() }.trackingErrorAlert(tracking)
    }
}

struct TrackingAccountView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject private var tracking = TrackingModel.shared
    let service: TrackingService
    @State private var clientID = ""
    @State private var signingOut = false
    var body: some View {
        TachiSettingsPage(title: service.name) {
            if let account = tracking.account(service) {
                TachiSectionTitle(L10n.string("Account"))
                HStack {
                    Text(account.viewer.name).shelfFont(.headline)
                    Spacer()
                    Button(L10n.string("Sign out"), role: .destructive) { signingOut = true }
                }.padding(18)
                Text(L10n.string("Signing out removes this device's token and stops pending requests. Revoke application access in your service account settings to invalidate access on the server."))
                    .shelfFont(.footnote).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18).padding(.bottom, 14)
            }
            TachiSectionTitle(L10n.string("Connection setup"))
            Text(L10n.string("Register a public client with the service, enter its client ID, and use the exact redirect URL below. A client secret is not stored in the app."))
                .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
            Link(destination: service.developerURL) { TachiLabel(L10n.string("Register an application"), systemImage: "arrow.up.right.square") }
                .padding(.horizontal, 18).frame(minHeight: 44)
            TextField(L10n.string("Public client ID"), text: $clientID)
                .textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).padding(18)
                .accessibilityIdentifier("tracking.client." + service.rawValue)
            Text(service.redirectURI).shelfFont(.subheadline).textSelection(.enabled).environment(\.layoutDirection, .leftToRight).padding(.horizontal, 18)
            Button { UIPasteboard.general.string = service.redirectURI } label: {
                Text(L10n.string("Copy redirect URL")).frame(minHeight: 44)
            }.padding(.horizontal, 18)
            if tracking.authenticatingService == service {
                ProgressView(L10n.string("Signing in…")).padding(18)
                Button { tracking.cancelAuthentication() } label: { Text(L10n.string("Cancel")).frame(minHeight: 44) }.padding(.horizontal, 18)
            } else {
                Button { tracking.signIn(service, clientID: clientID) } label: {
                    Text(tracking.account(service) == nil ? L10n.string("Sign in") : L10n.string("Reconnect"))
                }
                    .buttonStyle(ShelfPrimaryButtonStyle()).padding(18).disabled(tracking.authenticatingService != nil)
                    .accessibilityIdentifier("tracking.signin." + service.rawValue)
            }
            TachiNavigationRow(title: L10n.string("Tracking updates"), symbol: "arrow.up.circle") { TrackingOutboxView(service: service) }
        }.task { await tracking.start(); clientID = tracking.clientID(service) }
            .confirmationDialog(L10n.string("Sign out"), isPresented: $signingOut, titleVisibility: .visible) {
                Button(L10n.string("Sign out"), role: .destructive) { Task { await tracking.signOut(service) } }
            } message: { Text(L10n.string("Your manga links and reading progress stay saved. Pending updates require this account to sign in again.")) }
            .trackingErrorAlert(tracking)
    }
}

struct SeriesTrackingView: View {
    @Environment(\.locale) private var interfaceLocale
    @EnvironmentObject private var online: OnlineModel
    @ObservedObject private var tracking = TrackingModel.shared
    let seriesID: String
    let title: String
    @State private var searching: TrackingService?
    @State private var unlinking: TrackingLink?
    private var localProgress: Int {
        guard let item = online.saved(seriesID) else { return 0 }
        return TrackingProgressPolicy.completedThrough(chapters: item.chapters, progress: item.progress)
    }
    var body: some View {
        TachiSettingsPage(title: L10n.string("Tracking")) {
            Text(title).shelfFont(.headline).padding(18)
            Text(L10n.format("Completed through chapter %@", String(localProgress))).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 18)
            ForEach(TrackingService.allCases) { service in
                TachiSectionTitle(service.name)
                if let link = tracking.state.links.first(where: { $0.seriesID == seriesID && $0.service == service }) {
                    TrackingLinkStatus(link: link)
                    HStack {
                        Button { unlinking = link } label: { Text(L10n.string("Unlink manga")).frame(minHeight: 44) }
                        Spacer()
                        if tracking.account(service)?.viewer.id == link.accountUserID {
                            NavigationLink { TrackingProgressEditor(link: link) } label: { Text(L10n.string("Review progress")).frame(minHeight: 44) }
                        }
                    }.padding(.horizontal, 18)
                } else if tracking.account(service) != nil {
                    Button { searching = service } label: { TachiLabel(L10n.string("Search and link manga"), systemImage: "magnifyingglass").frame(minHeight: 44) }.padding(.horizontal, 18)
                } else {
                    TachiNavigationRow(title: L10n.string("Sign in"), symbol: "person.crop.circle") { TrackingAccountView(service: service) }
                }
            }
        }.task { await tracking.start() }
            .sheet(item: $searching) { service in
                NavigationStack { TrackingSearchView(service: service, seriesID: seriesID, title: title, localProgress: localProgress) }
                    .tachiSheet()
            }
            .confirmationDialog(L10n.string("Unlink manga"), isPresented: Binding(get: { unlinking != nil }, set: { if !$0 { unlinking = nil } }), titleVisibility: .visible) {
                if let link = unlinking {
                    Button(L10n.string("Unlink manga"), role: .destructive) { unlinking = nil; Task { await tracking.unlink(link.id) } }
                }
            } message: { Text(L10n.string("The manga remains on the tracking service. Your local reading progress is preserved.")) }
            .trackingErrorAlert(tracking)
    }
}

private struct TrackingSearchView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var tracking = TrackingModel.shared
    let service: TrackingService
    let seriesID: String
    let title: String
    let localProgress: Int
    @State private var query = ""
    @State private var results: [TrackingMedia] = []
    @State private var busy = false
    @State private var searched = false
    @State private var message: String?
    @State private var preview: TrackingMatchPreview?
    @State private var showPreview = false
    @State private var operation: Task<Void, Never>?
    @State private var revision = UUID()
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                TextField(L10n.string("Search titles…"), text: $query).textFieldStyle(.roundedBorder).submitLabel(.search).onSubmit { search() }
                Button { search() } label: { TachiIcon(symbol: "magnifyingglass", size: 24).frame(width: 44, height: 44) }.accessibilityLabel(L10n.string("Search"))
            }.padding(.horizontal, 16)
            if busy { ProgressView().padding() }
            if let message { Text(message).shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(.horizontal, 16) }
            if searched && results.isEmpty && !busy { ShelfEmptyState(title: L10n.string("No results")) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { media in
                        Button { inspect(media) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(media.title).shelfFont(.body).foregroundStyle(ShelfStyle.text)
                                Text([media.format, media.totalChapters.map { L10n.format("%@ chapters", String($0)) }].compactMap { $0 }.joined(separator: " · "))
                                    .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(busy)
                    }
                }
            }
            Button { dismiss() } label: { Text(L10n.string("Close")).frame(minHeight: 44) }
        }.tachiPage(service.name).onAppear { if query.isEmpty { query = title } }.onDisappear { operation?.cancel() }
            .navigationDestination(isPresented: $showPreview) {
                if let preview { TrackingMatchView(seriesID: seriesID, localTitle: title, preview: preview, localProgress: localProgress, onLinked: { dismiss() }) }
            }.trackingErrorAlert(tracking)
    }
    private func search() {
        operation?.cancel(); let id = UUID(); revision = id; busy = true; message = nil
        operation = Task {
            defer { if revision == id { busy = false } }
            do { let found = try await tracking.search(service, query: query); try Task.checkCancellation(); if revision == id { results = found; searched = true } }
            catch is CancellationError { }
            catch { if revision == id { message = trackingDescription(error) } }
        }
    }
    private func inspect(_ media: TrackingMedia) {
        operation?.cancel(); let id = UUID(); revision = id; busy = true; message = nil
        operation = Task {
            defer { if revision == id { busy = false } }
            do { let value = try await tracking.preview(service, id: media.id); try Task.checkCancellation(); if revision == id { preview = value; showPreview = true } }
            catch is CancellationError { }
            catch { if revision == id { message = trackingDescription(error) } }
        }
    }
}

private struct TrackingMatchView: View {
    @ObservedObject private var tracking = TrackingModel.shared
    let seriesID: String
    let localTitle: String
    let preview: TrackingMatchPreview
    let localProgress: Int
    let onLinked: () -> Void
    @State private var linking = false
    @State private var pullRemote = false
    var body: some View {
        TachiSettingsPage(title: L10n.string("Confirm manga match")) {
            Text(localTitle).shelfFont(.headline).padding(18)
            Text(preview.media.title).shelfFont(.title3).padding(.horizontal, 18)
            Link(L10n.string("View on tracking service"), destination: URL(string: preview.media.website)!).padding(18)
            LabeledContent(L10n.string("Local chapters read"), value: String(localProgress)).padding(.horizontal, 18).padding(.vertical, 8)
            LabeledContent(L10n.string("Remote chapters read"), value: String(preview.media.entry.progress)).padding(.horizontal, 18).padding(.vertical, 8)
            if preview.media.entry.progress > localProgress {
                Text(L10n.string("Remote progress is ahead. It will be kept; this app will not send a lower chapter count."))
                    .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
                if tracking.applyRemoteProgress != nil {
                    TachiToggleRow(title: L10n.string("Apply remote progress locally"), symbol: "arrow.down.circle", isOn: $pullRemote)
                }
            }
            Text(L10n.string("Check the edition and title before linking. A link is saved locally; its progress update stays queued until the service confirms it."))
                .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
            Button {
                linking = true
                Task {
                    let linked = await tracking.link(seriesID: seriesID, preview: preview, localProgress: localProgress)
                    if linked, pullRemote, let link = tracking.state.links.first(where: { $0.seriesID == seriesID && $0.service == preview.service }) {
                        await tracking.applyRemote(link, progress: preview.media.entry.progress)
                    }
                    linking = false; if linked { onLinked() }
                }
            } label: { Text(L10n.string("Link this manga")) }.buttonStyle(ShelfPrimaryButtonStyle()).padding(18).disabled(linking)
        }.trackingErrorAlert(tracking)
    }
}

private struct TrackingLinkStatus: View {
    @ObservedObject private var tracking = TrackingModel.shared
    let link: TrackingLink
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(link.mediaTitle).shelfFont(.headline)
            Text(L10n.string("Title linked")).shelfFont(.caption).foregroundStyle(ShelfStyle.accent)
            if let delivery = tracking.delivery(link.id) {
                Text(trackingPhase(delivery.phase)).shelfFont(.subheadline)
                Text(L10n.format("Remote: %@ · Queued: %@", String(link.remoteProgress), String(delivery.desiredProgress)))
                    .shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                if let failure = delivery.failure { Text(trackingFailureLabel(failure)).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary) }
                if let date = delivery.nextAttemptAt, delivery.phase == .waiting {
                    Text(date, style: .relative).shelfFont(.caption).foregroundStyle(ShelfStyle.secondary)
                }
                if delivery.phase == .failed || delivery.phase == .waiting {
                    Button { Task { await tracking.retry(link.id) } } label: { Text(L10n.string("Retry")).frame(minHeight: 44) }
                } else if delivery.phase == .authenticationRequired {
                    TachiNavigationRow(title: L10n.string("Sign in"), symbol: "person.crop.circle") { TrackingAccountView(service: link.service) }
                } else if delivery.phase == .remoteAhead {
                    HStack {
                        Button { Task { await tracking.keepRemote(link.id) } } label: { Text(L10n.string("Keep remote progress")).frame(minHeight: 44) }
                        if tracking.applyRemoteProgress != nil {
                            Button { Task { await tracking.applyRemote(link, progress: delivery.observedRemoteProgress ?? link.remoteProgress) } } label: {
                                Text(L10n.string("Apply locally")).frame(minHeight: 44)
                            }
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
    }
}

struct TrackingOutboxView: View {
    @ObservedObject private var tracking = TrackingModel.shared
    var service: TrackingService? = nil
    private var links: [TrackingLink] { tracking.state.links.filter { service == nil || $0.service == service } }
    var body: some View {
        TachiList {
            if links.isEmpty { ShelfEmptyState(title: L10n.string("No linked manga")) }
            ForEach(links) { link in
                VStack(alignment: .leading, spacing: 0) {
                    Text(link.service.name).shelfFont(.caption).foregroundStyle(ShelfStyle.accent).padding(.horizontal, 18)
                    TrackingLinkStatus(link: link)
                    NavigationLink { TrackingProgressEditor(link: link) } label: { Text(L10n.string("Review progress")).frame(minHeight: 44) }.padding(.horizontal, 18)
                }
            }
        }.tachiPage(L10n.string("Tracking updates")).task { await tracking.start() }.trackingErrorAlert(tracking)
    }
}

private struct TrackingProgressEditor: View {
    @ObservedObject private var tracking = TrackingModel.shared
    let link: TrackingLink
    @State private var progress = 0
    @State private var confirming = false
    var body: some View {
        TachiSettingsPage(title: L10n.string("Review progress")) {
            Text(link.mediaTitle).shelfFont(.headline).padding(18)
            Text(L10n.string("Use this review for sources with numbering gaps. Sending this count updates only the selected tracking service."))
                .shelfFont(.subheadline).foregroundStyle(ShelfStyle.secondary).padding(18)
            Stepper(value: $progress, in: link.remoteProgress...1_000_000) { Text(L10n.format("Chapter %@", String(progress))) }.padding(18)
            Button { confirming = true } label: { Text(L10n.string("Queue progress update")) }.buttonStyle(ShelfPrimaryButtonStyle()).padding(18)
        }.onAppear { progress = max(link.remoteProgress, link.desiredProgress) }
            .confirmationDialog(L10n.string("Queue progress update"), isPresented: $confirming, titleVisibility: .visible) {
                Button(L10n.string("Confirm")) { Task { await tracking.setProgress(link.id, progress: progress) } }
            } message: { Text(L10n.format("Send chapter %@ to %@?", String(progress), link.service.name)) }
            .trackingErrorAlert(tracking)
    }
}

private func trackingPhase(_ phase: TrackingDeliveryPhase) -> String {
    switch phase {
    case .pending: return L10n.string("Update queued")
    case .sending: return L10n.string("Sending progress…")
    case .waiting: return L10n.string("Waiting to retry")
    case .failed: return L10n.string("Update failed")
    case .authenticationRequired: return L10n.string("Sign in to send progress")
    case .remoteAhead: return L10n.string("Remote progress is ahead")
    case .complete: return L10n.string("Progress is up to date")
    }
}
private func trackingFailureLabel(_ code: TrackingFailureCode) -> String {
    switch code {
    case .authentication: return L10n.string("Your tracking session expired. Sign in again.")
    case .network: return L10n.string("Could not connect to the tracking service. Your update remains saved.")
    case .rateLimit: return L10n.string("The service asked us to wait before retrying.")
    case .service: return L10n.string("The tracking service could not accept this update.")
    case .invalidResponse: return L10n.string("The tracking service returned an invalid response.")
    case .storage: return L10n.string("Could not save tracking data. Try again.")
    }
}
private extension View {
    func trackingErrorAlert(_ model: TrackingModel) -> some View {
        alert(L10n.string("Tracking"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.string("OK"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
