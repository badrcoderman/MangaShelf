import SwiftUI

/// Counts foreground time only while a rendered page is visible and no reader sheet is open.
/// Flushes before changing the running state so a periodic flush and a close cannot count twice.
struct ReaderActivityModifier: ViewModifier {
    let active: Bool
    let record: (TimeInterval) async -> Void
    @State private var started: Date?
    @EnvironmentObject private var privacy: AppPrivacy
    @ObservedObject private var maintenance = BackupMaintenance.shared
    private var running: Bool { active && !maintenance.isActive && !privacy.locked }
    func body(content: Content) -> some View {
        content
            .onAppear { if running { started = Date() } }
            .onChange(of: running) { _, running in
                flush(restart: running)
            }
            .task(id: running) {
                guard running else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)); try Task.checkCancellation() } catch { return }
                    flush(restart: true)
                }
            }
            .onDisappear { flush(restart: false) }
    }
    private func flush(restart: Bool) {
        let now = Date(), previous = started
        started = restart ? now : nil
        guard let previous else { return }
        let duration = now.timeIntervalSince(previous)
        guard duration.isFinite, duration > 0, duration <= 3600 else { return }
        Task { await record(duration) }
    }
}
