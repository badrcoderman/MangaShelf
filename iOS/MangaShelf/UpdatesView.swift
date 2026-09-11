import SwiftUI
import ReaderCore

struct UpdatesView: View {
    @EnvironmentObject private var model: AppModel
    private var additions: [LibraryBook] { model.state.books.sorted { $0.addedAt > $1.addedAt } }
    var body: some View {
        List {
            if additions.isEmpty && model.state.repositories.isEmpty {
                ContentUnavailableView("لا توجد تحديثات", systemImage: "arrow.triangle.2.circlepath", description: Text("تظهر هنا آخر إضافات المكتبة وتحديثات فهارس المستودعات."))
            }
            if !model.state.repositories.isEmpty {
                Section {
                    ForEach(model.state.repositories.sorted { $0.fetchedAt > $1.fetchedAt }) { repository in
                        HStack(spacing: 12) {
                            Image(systemName: "shippingbox").foregroundStyle(.blue).frame(width: 36)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(repository.index.name).font(.subheadline.weight(.medium))
                                Text("تحديث فهرس — \(repository.index.extensions.count) إضافة").font(.caption).foregroundStyle(.secondary)
                                Text(repository.fetchedAt, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5)
                    }
                } header: { Text("فهارس المستودعات") } footer: { Text("تحديث الفهرس يجلب قائمة الإضافات؛ متابعة الفصول الجديدة ليست متاحة في هذه النسخة بعد.") }
            }
            if !additions.isEmpty {
                Section("آخر إضافات المكتبة") {
                    ForEach(additions) { book in
                        NavigationLink { BookDetailView(bookID: book.id) } label: {
                            HStack(spacing: 12) {
                                BookCover(book: book).frame(width: 44).clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                    Text("أُضيف للمكتبة — \(book.pageCount) صفحة").font(.caption).foregroundStyle(.secondary)
                                    Text(book.addedAt, format: .dateTime.day().month().hour().minute()).font(.caption2).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 3)
                        }
                    }
                }
            }
        }.listStyle(.plain)
            .navigationTitle("التحديثات").navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.refreshAllRepositories() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.refreshingRepositories { ProgressView().controlSize(.small) }
                    else {
                        Button("تحديث الفهارس", systemImage: "arrow.clockwise") { Task { await model.refreshAllRepositories() } }
                            .disabled(model.state.repositories.isEmpty)
                    }
                }
            }
    }
}
