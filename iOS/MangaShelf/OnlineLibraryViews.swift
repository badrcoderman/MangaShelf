import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct DownloadsView: View {
    @EnvironmentObject private var online: OnlineModel
    @State private var reading: MangaChapter?
    @State private var removing: String?
    var body: some View {
        List {
            if online.state.downloads.isEmpty { ContentUnavailableView("قائمة التنزيلات فارغة", systemImage: "arrow.down.circle", description: Text("اختر تنزيلًا من قائمة فصول أي عنوان.")) }
            ForEach(online.state.downloads) { job in
                VStack(alignment: .leading, spacing: 9) {
                    Text(online.saved(job.chapter.seriesID)?.series.title ?? "عنوان").font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(job.chapter.displayTitle).font(.subheadline)
                    HStack {
                        Label(phaseLabel(job.phase), systemImage: job.phase == .complete ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(job.phase == .failed ? Color.red : Color.secondary)
                        Spacer(); Text("\(job.finishedPages) / \(job.totalPages)").monospacedDigit()
                    }.font(.caption)
                    if job.totalPages > 0 { ProgressView(value: Double(job.finishedPages), total: Double(job.totalPages)) }
                    if let error = job.failure { Text(error).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        if job.phase == .complete { Button("قراءة دون اتصال") { reading = job.chapter } }
                        else if job.phase == .failed || job.phase == .paused { Button("استئناف") { Task { await online.enqueue([job.chapter]) } } }
                        Spacer(); Button("حذف", role: .destructive) { removing = job.id }
                    }.font(.caption).buttonStyle(.borderless)
                }.padding(.vertical, 7)
            }
            if !online.state.downloads.isEmpty {
                Section { Text("عند إغلاق التطبيق قد يوقف iOS التنزيل. الصفحات المكتملة تبقى محفوظة، ويمكن استئناف الباقي من هنا.").font(.footnote).foregroundStyle(.secondary) }
            }
        }.shelfPage().navigationTitle("التنزيلات").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if online.downloading { Button("إيقاف مؤقت", systemImage: "pause") { Task { await online.pauseDownloads() } } }
                else { Button("استئناف الكل", systemImage: "play") { Task { await online.resumeDownloads() } }.disabled(online.state.downloads.allSatisfy { $0.phase == .complete }) }
            }
            .fullScreenCover(item: $reading) { OnlineReaderView(chapter: $0) }
            .confirmationDialog("حذف صفحات هذا الفصل من الجهاز؟", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                if let id = removing { Button("حذف التنزيل", role: .destructive) { Task { await online.deleteDownload(id) }; removing = nil } }
            } message: { Text("يبقى تقدم القراءة والعنوان في المكتبة.") }
    }
    private func phaseLabel(_ phase: DownloadPhase) -> String {
        switch phase { case .queued: return "في الانتظار"; case .downloading: return "جارٍ التنزيل"; case .paused: return "متوقف مؤقتًا"; case .failed: return "تعذر التنزيل"; case .complete: return "متاح دون اتصال" }
    }
}

struct OnlineBackupView: View {
    @EnvironmentObject private var online: OnlineModel
    @State private var exporting = false
    @State private var importing = false
    @State private var document = MetadataBackup(data: Data())
    var body: some View {
        Form {
            Section {
                Button("تصدير مكتبة المصادر والتقدم") {
                    Task {
                        do { document = MetadataBackup(data: try await online.backup()); exporting = true }
                        catch { online.errorMessage = ArabicError.describe(error) }
                    }
                }
                Button("استعادة ودمج نسخة") { importing = true }
            } footer: { Text("تشمل العناوين والفصول والتقدم والعلامات. صور الفصول المنزّلة غير مضمنة. الدمج يحتفظ بالتقدم الأحدث ولا يحذف مكتبتك الحالية.") }
        }.shelfPage().navigationTitle("نسخة مكتبة المصادر").navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "MangaShelf-online-backup") { result in
                if case .failure(let error) = result { online.errorMessage = ArabicError.describe(error) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                switch result { case .success(let url): Task { await online.restore(url) }; case .failure(let error): online.errorMessage = ArabicError.describe(error) }
            }
    }
}
