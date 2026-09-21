import XCTest
import CryptoKit
@testable import ReaderCore

final class PhaseThreeLibraryTests: XCTestCase {

    private func createTempDir() throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("mangashelf-p3-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    private func createDummyArchive() -> Data {
        // Minimal valid CBZ archive containing page1.jpg
        return Data([
            80, 75, 3, 4, 20, 0, 0, 0, 0, 0, 0, 132, 53, 93, 200, 93, 61, 198, 4, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0,
            112, 97, 103, 101, 49, 46, 106, 112, 103, 255, 216, 255, 224, 80, 75, 1, 2, 20, 3, 20, 0, 0, 0,
            0, 0, 0, 132, 53, 93, 200, 93, 61, 198, 4, 0, 0, 0, 4, 0, 0, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            128, 1, 0, 0, 0, 0, 112, 97, 103, 101, 49, 46, 106, 112, 103, 80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 55, 0, 0, 0,
            43, 0, 0, 0, 0, 0
        ])
    }

    func testBatchCategoryAssignmentAndCompletion() async throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: root)
        try await store.addCategory("Shonen")
        try await store.addCategory("Action")
        let categories = await store.snapshot().categories
        XCTAssertEqual(categories.count, 2)
        let catIDs = Set(categories.map(\.id))

        let dummyData = createDummyArchive()
        let file1 = root.appendingPathComponent("comic1.cbz")
        let file2 = root.appendingPathComponent("comic2.cbz")
        try dummyData.write(to: file1)
        try dummyData.write(to: file2)

        let book1 = try await store.importComic(from: file1)
        let book2 = try await store.importComic(from: file2)

        // Batch assign categories
        try await store.batchAssignCategories(bookIDs: [book1.id, book2.id], categoryIDs: catIDs)
        let snapshot1 = await store.snapshot()
        XCTAssertEqual(snapshot1.books.first { $0.id == book1.id }?.categories, catIDs)
        XCTAssertEqual(snapshot1.books.first { $0.id == book2.id }?.categories, catIDs)

        // Batch set completed
        try await store.batchSetCompleted(bookIDs: [book1.id, book2.id], completed: true)
        let snapshot2 = await store.snapshot()
        XCTAssertEqual(snapshot2.books.first { $0.id == book1.id }?.completed, true)
        XCTAssertEqual(snapshot2.books.first { $0.id == book2.id }?.completed, true)
    }

    func testSoftDeletionAndTrashRestoration() async throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: root)
        let dummyData = createDummyArchive()
        let file = root.appendingPathComponent("soft_delete_test.cbz")
        try dummyData.write(to: file)
        let book = try await store.importComic(from: file)

        let bookURL = await store.bookURL(book)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookURL.path))

        // Move to trash
        try await store.batchMoveToTrash(ids: [book.id])
        let trashedSnapshot = await store.snapshot()
        let trashedBook = trashedSnapshot.books.first { $0.id == book.id }
        XCTAssertNotNil(trashedBook)
        XCTAssertTrue(trashedBook?.isDeleted == true)
        XCTAssertNotNil(trashedBook?.deletedAt)

        let trashURL = await store.trashURL(book)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Books").appendingPathComponent(book.filename).path))

        // Restore from trash
        try await store.batchRestoreFromTrash(ids: [book.id])
        let restoredSnapshot = await store.snapshot()
        let restoredBook = restoredSnapshot.books.first { $0.id == book.id }
        XCTAssertNotNil(restoredBook)
        XCTAssertFalse(restoredBook?.isDeleted == true)
        XCTAssertNil(restoredBook?.deletedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Books").appendingPathComponent(book.filename).path))
    }

    func testPermanentDeletionAndEmptyTrash() async throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: root)
        let dummyData = createDummyArchive()
        let file = root.appendingPathComponent("empty_trash_test.cbz")
        try dummyData.write(to: file)
        let book = try await store.importComic(from: file)

        try await store.moveToTrash(id: book.id)
        let trashCount = await store.snapshot().books.filter(\.isDeleted).count
        XCTAssertEqual(trashCount, 1)

        try await store.emptyTrash()
        let emptySnapshot = await store.snapshot()
        XCTAssertEqual(emptySnapshot.books.count, 0)
        let trashURL = await store.trashURL(book)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashURL.path))
    }

    func testCategoryDisplayOptionsPersistence() async throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: root)
        try await store.addCategory("Favorites")
        let categoryID = (await store.snapshot().categories.first)!.id

        let customOptions = CategoryDisplayOptions(sortOption: .title, sortAscending: true, displayMode: .list, columnCount: 1)
        try await store.setCategoryDisplayOptions(categoryID: categoryID, options: customOptions)

        let defaultOptions = CategoryDisplayOptions(sortOption: .recent, sortAscending: false, displayMode: .gridCompact, columnCount: 3)
        try await store.setCategoryDisplayOptions(categoryID: nil, options: defaultOptions)

        // Reload store from disk
        let reloadedStore = try LibraryStore(root: root)
        let snapshot = await reloadedStore.snapshot()
        XCTAssertEqual(snapshot.categoryPreferences[categoryID]?.displayMode, .list)
        XCTAssertEqual(snapshot.categoryPreferences[categoryID]?.sortOption, .title)
        XCTAssertEqual(snapshot.categoryPreferences[categoryID]?.sortAscending, true)
        XCTAssertEqual(snapshot.defaultDisplayOptions.displayMode, .gridCompact)
        XCTAssertEqual(snapshot.defaultDisplayOptions.sortOption, .recent)
    }

    func testPersonalNotesAndReadingTime() async throws {
        let root = try createTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try LibraryStore(root: root)
        let dummyData = createDummyArchive()
        let file = root.appendingPathComponent("notes_test.cbz")
        try dummyData.write(to: file)
        let book = try await store.importComic(from: file)

        try await store.setBookNotes(id: book.id, notes: "Recommended by friend. Excellent chapter 1!")
        try await store.addReadingTime(id: book.id, duration: 1800) // 30 minutes

        let snapshot = await store.snapshot()
        let updated = snapshot.books.first { $0.id == book.id }
        XCTAssertEqual(updated?.notes, "Recommended by friend. Excellent chapter 1!")
        XCTAssertEqual(updated?.totalReadingTime, 1800)
    }

    func testDexBytecodeInspection() throws {
        // Construct valid ZIP archive containing classes.dex with DEX magic bytes: 0x64 0x65 0x78 0x0A ("dex\n")
        let dexData = Data([
            80, 75, 3, 4, 20, 0, 0, 0, 0, 0, 172, 164, 53, 93, 185, 228, 251, 49, 8, 0, 0, 0, 8, 0, 0, 0, 11, 0, 0, 0,
            99, 108, 97, 115, 115, 101, 115, 46, 100, 101, 120,
            100, 101, 120, 10, 48, 51, 53, 0,
            80, 75, 1, 2, 20, 3, 20, 0, 0, 0, 0, 0, 172, 164, 53, 93, 185, 228, 251, 49, 8, 0, 0, 0, 8, 0, 0, 0, 11, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 128, 1, 0, 0, 0, 0,
            99, 108, 97, 115, 115, 101, 115, 46, 100, 101, 120,
            80, 75, 5, 6, 0, 0, 0, 0, 1, 0, 1, 0, 57, 0, 0, 0, 49, 0, 0, 0, 0, 0
        ])

        let inspection = try JARInspection.inspect(dexData)
        XCTAssertEqual(inspection.entries, 1)
        XCTAssertTrue(inspection.classes.contains("classes.dex"))
    }
}
