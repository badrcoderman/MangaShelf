import SwiftUI
import ReaderCore

struct BackupHubView: View {
    var body: some View {
        List {
            NavigationLink { BackupPreferencesView() } label: { SettingsRow(title: "نسخة الكتب المحلية", symbol: "books.vertical") }
            NavigationLink { OnlineBackupView().shelfPage() } label: { SettingsRow(title: "نسخة مكتبة المصادر", symbol: "safari") }
        }.listStyle(.plain).shelfPage().navigationTitle("النسخ الاحتياطي والاستعادة").navigationBarTitleDisplayMode(.inline)
    }
}

struct GeneralPreferencesView: View {
    var body: some View {
        Form {
            Section("الواجهة") {
                LabeledContent("اللغة", value: "العربية")
                LabeledContent("اتجاه الواجهة", value: "من اليمين إلى اليسار")
            }
            Section {
                NavigationLink { SourcePreferencesView().shelfPage() } label: { Text("إعدادات المصادر") }
                NavigationLink { StorageView().shelfPage() } label: { Text("إدارة التخزين") }
            }
        }.shelfPage().navigationTitle("عام").navigationBarTitleDisplayMode(.inline)
    }
}

struct LibraryPreferencesView: View {
    @AppStorage("library.columns") private var columns = 2
    @AppStorage("library.sort") private var sorting = "added"
    var body: some View {
        Form {
            Section("العرض") {
                Stepper("عدد الأعمدة: \(columns)", value: $columns, in: 2...5)
                Picker("ترتيب العناوين", selection: $sorting) {
                    Text("تاريخ الإضافة").tag("added"); Text("العنوان").tag("title"); Text("آخر قراءة").tag("recent")
                }
            }
            NavigationLink { CategoryManagementView() } label: { Text("إدارة التصنيفات") }
        }.shelfPage().navigationTitle("المكتبة").navigationBarTitleDisplayMode(.inline)
    }
}

/// Honest availability information for features scheduled after the interface phase.
/// These destinations contain no switches that pretend to enable an absent service.
struct FeatureStatusView: View {
    enum Feature {
        case sync, tracking, migration
        var title: String {
            switch self { case .sync: return "مزامنة"; case .tracking: return "يتتبع"; case .migration: return "ترحيل" }
        }
        var message: String {
            switch self {
            case .sync: return "المزامنة بين الأجهزة غير متاحة في هذا الإصدار. يمكنك تصدير بيانات مكتبتك من النسخ الاحتياطي."
            case .tracking: return "ربط خدمات تتبع القراءة غير متاح في هذا الإصدار. يُحفظ تقدم قراءتك داخل التطبيق."
            case .migration: return "نقل عنوان بين مصدرين غير متاح حتى اكتمال تشغيل إضافات المصادر."
            }
        }
    }
    let feature: Feature
    var body: some View {
        VStack(spacing: 12) {
            ShelfEmptyState(title: "غير متاح حاليًا", message: feature.message)
            if feature == .sync { NavigationLink("النسخ الاحتياطي") { BackupHubView() } }
            if feature == .migration { NavigationLink("المستودعات") { RepositoriesView() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).shelfPage()
            .navigationTitle(feature.title).navigationBarTitleDisplayMode(.inline)
    }
}

struct PrivacyPreferencesView: View {
    var body: some View {
        List {
            Section("البيانات") {
                Text("تُحفظ مكتبتك وتقدم القراءة على جهازك. احتفظ بالنسخ التي تصدّرها في مكان تثق به.")
                Text("عند استخدام مصدر، يُرسل طلب البحث أو الفصل إلى ذلك المصدر لتحميل المحتوى.")
            }
            Section("التحكم") {
                NavigationLink { StorageView().shelfPage() } label: { Text("عرض التخزين") }
                NavigationLink { RepositoriesView() } label: { Text("إدارة المستودعات") }
            }
        }.shelfPage().navigationTitle("إعدادات الأمان").navigationBarTitleDisplayMode(.inline)
    }
}

struct ReadingInsightsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var online: OnlineModel
    private var readChapters: Int { online.state.series.reduce(0) { $0 + $1.progress.values.filter(\.read).count } }
    var body: some View {
        List {
            Section("المكتبة") {
                LabeledContent("كتب محلية", value: "\(model.state.books.count)")
                LabeledContent("عناوين المصادر", value: "\(online.state.series.filter(\.inLibrary).count)")
                LabeledContent("تصنيفات", value: "\(model.state.categories.count)")
            }
            Section("القراءة") {
                LabeledContent("كتب محلية مكتملة", value: "\(model.state.books.filter(\.completed).count)")
                LabeledContent("فصول محددة كمقروءة", value: "\(readChapters)")
                LabeledContent("فصول منزّلة", value: "\(online.state.downloads.filter { $0.phase == .complete }.count)")
            }
        }.shelfPage().navigationTitle("رؤى القراءة").navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("الكتب المحلية") { Text("من المكتبة، افتح قائمة الخيارات ثم اختر استيراد كتاب. يمكنك استيراد ملفات CBZ أو ZIP التي تحتوي على صور.") }
            Section("المصادر") { Text("افتح تصفح ثم اختر مصدرًا متاحًا. ابحث عن العنوان، وافتح تفاصيله ثم أضفه إلى المكتبة أو ابدأ القراءة.") }
            Section("التنزيلات") { Text("افتح قائمة فصول العنوان واضغط زر التنزيل. تظهر حالة الفصول في المزيد ← التنزيلات.") }
            Section("الإضافات") { Text("إضافة مستودع تعرض فهرسه فقط في هذا الإصدار. تشغيل إضافات JAR لم يتوفر بعد.") }
        }.shelfPage().navigationTitle("مساعدة").navigationBarTitleDisplayMode(.inline)
    }
}
