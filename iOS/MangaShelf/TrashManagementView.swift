import SwiftUI
import ReaderCore

struct TrashManagementView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var confirmingEmptyTrash = false
    @State private var bookToPermanentlyDelete: LibraryBook?
    @State private var isMultiSelect = false
    @State private var selectedIDs: Set<UUID> = []

    private var trashed: [LibraryBook] { model.trashedBooks }

    var body: some View {
        VStack(spacing: 0) {
            if isMultiSelect && !trashed.isEmpty {
                HStack {
                    Text(L10n.format("%@ selected", String(describing: selectedIDs.count)))
                        .font(.subheadline.bold())
                    Spacer()
                    Button(selectedIDs.count == trashed.count ? L10n.string("Deselect all") : L10n.string("Select all")) {
                        if selectedIDs.count == trashed.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(trashed.map(\.id)) }
                    }.font(.caption)
                    Button(L10n.string("Done")) {
                        isMultiSelect = false; selectedIDs.removeAll()
                    }.font(.caption.bold())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(ShelfStyle.header)
            }

            if trashed.isEmpty {
                Spacer()
                ShelfEmptyState(title: L10n.string("Trash is empty"),
                                message: L10n.string("Deleted titles will appear here and can be restored."))
                Spacer()
            } else {
                List {
                    ForEach(trashed) { book in
                        HStack(spacing: 12) {
                            if isMultiSelect {
                                Button {
                                    if selectedIDs.contains(book.id) { selectedIDs.remove(book.id) }
                                    else { selectedIDs.insert(book.id) }
                                } label: {
                                    Image(systemName: selectedIDs.contains(book.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedIDs.contains(book.id) ? ShelfStyle.accent : ShelfStyle.secondary)
                                        .font(.title3)
                                }.buttonStyle(.plain)
                            }
                            BookCover(book: book)
                                .frame(width: 48, height: 68)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(book.title).font(.body.weight(.medium)).lineLimit(2)
                                if let deletedAt = book.deletedAt {
                                    Text(L10n.format("Deleted: %@", deletedAt.formatted(date: .abbreviated, time: .shortened)))
                                        .font(.caption).foregroundStyle(ShelfStyle.secondary)
                                }
                                Text(L10n.format("%@ pages", String(describing: book.pageCount)))
                                    .font(.caption2).foregroundStyle(ShelfStyle.secondary)
                            }
                            Spacer()
                            if !isMultiSelect {
                                Menu {
                                    Button {
                                        Task { await model.batchRestoreFromTrash(bookIDs: [book.id]) }
                                    } label: {
                                        Label(L10n.string("Restore"), systemImage: "arrow.uturn.backward")
                                    }
                                    Button(role: .destructive) {
                                        bookToPermanentlyDelete = book
                                    } label: {
                                        Label(L10n.string("Delete permanently"), systemImage: "trash")
                                    }
                                } label: {
                                    ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90))
                                        .foregroundStyle(ShelfStyle.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(ShelfStyle.card)
                    }
                }
                .listStyle(.plain)

                if isMultiSelect && !selectedIDs.isEmpty {
                    HStack(spacing: 16) {
                        Button {
                            Task {
                                await model.batchRestoreFromTrash(bookIDs: Array(selectedIDs))
                                selectedIDs.removeAll()
                                isMultiSelect = false
                            }
                        } label: {
                            Label(L10n.string("Restore selected"), systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ShelfPrimaryButtonStyle())

                        Button(role: .destructive) {
                            Task {
                                await model.permanentlyDelete(bookIDs: Array(selectedIDs))
                                selectedIDs.removeAll()
                                isMultiSelect = false
                            }
                        } label: {
                            Label(L10n.string("Delete"), systemImage: "trash")
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color.red.opacity(0.15))
                                .foregroundStyle(Color.red)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                    .background(ShelfStyle.header)
                }
            }
        }
        .shelfPage()
        .navigationTitle(L10n.string("Trash"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !trashed.isEmpty && !isMultiSelect {
                    Menu {
                        Button {
                            isMultiSelect = true
                        } label: {
                            Label(L10n.string("Select titles"), systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive) {
                            confirmingEmptyTrash = true
                        } label: {
                            Label(L10n.string("Empty trash"), systemImage: "trash")
                        }
                    } label: {
                        ShelfIcon(symbol: "ellipsis").rotationEffect(.degrees(90))
                    }
                }
            }
        }
        .confirmationDialog(L10n.string("Empty trash?"), isPresented: $confirmingEmptyTrash, titleVisibility: .visible) {
            Button(L10n.string("Empty trash"), role: .destructive) {
                Task { await model.emptyTrash() }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("All items in trash will be permanently deleted from device storage. This action cannot be undone."))
        }
        .confirmationDialog(L10n.string("Delete this title permanently?"), isPresented: Binding(get: { bookToPermanentlyDelete != nil }, set: { if !$0 { bookToPermanentlyDelete = nil } }), titleVisibility: .visible) {
            if let book = bookToPermanentlyDelete {
                Button(L10n.string("Delete permanently"), role: .destructive) {
                    Task {
                        await model.permanentlyDelete(bookIDs: [book.id])
                        bookToPermanentlyDelete = nil
                    }
                }
            }
            Button(L10n.string("Cancel"), role: .cancel) { bookToPermanentlyDelete = nil }
        } message: {
            if let book = bookToPermanentlyDelete {
                Text(L10n.format("The comic file for \"%@\" will be removed permanently.", book.title))
            }
        }
    }
}
