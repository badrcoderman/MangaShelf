import SwiftUI
import UIKit
import Observation

/// View reads participate in Observation, including reads through ShelfStyle.
/// These preferences apply to the interface; reader overrides stay independent.
@Observable final class InterfaceState {
    static let shared = InterfaceState()
    private let defaults = UserDefaults.standard
    var palette: String { didSet { defaults.set(palette, forKey: "appearance.palette") } }
    var pureBlack: Bool { didSet { defaults.set(pureBlack, forKey: "appearance.pureBlack") } }
    var liquidGlass: Bool { didSet { defaults.set(liquidGlass, forKey: "appearance.liquidGlass") } }
    var blend: Double { didSet { defaults.set(blend, forKey: "appearance.blend") } }
    var dateFormat: String { didSet { defaults.set(dateFormat, forKey: "appearance.dateFormat") } }
    var rotation: String { didSet { defaults.set(rotation, forKey: "appearance.rotation") } }
    var tabOrder: String { didSet { defaults.set(tabOrder, forKey: "tabs.order") } }
    var hiddenTabs: String { didSet { defaults.set(hiddenTabs, forKey: "tabs.hidden") } }
    var tabLabels: Bool { didSet { defaults.set(tabLabels, forKey: "tabs.labels") } }
    var defaultTab: Int { didSet { defaults.set(defaultTab, forKey: "tabs.default") } }
    var persistentTabs: Bool { didSet { defaults.set(persistentTabs, forKey: "tabs.persistent") } }
    var coverRevision = UUID()

    private init() {
        let stored = UserDefaults.standard
        palette = stored.string(forKey: "appearance.palette") ?? "default"
        pureBlack = stored.bool(forKey: "appearance.pureBlack")
        liquidGlass = stored.object(forKey: "appearance.liquidGlass") as? Bool ?? true
        let savedBlend = stored.object(forKey: "appearance.blend") as? Double ?? 10
        blend = savedBlend.isFinite ? min(30, max(0, savedBlend)) : 10
        dateFormat = stored.string(forKey: "appearance.dateFormat") ?? "relative"
        rotation = stored.string(forKey: "appearance.rotation") ?? "device"
        tabOrder = stored.string(forKey: "tabs.order") ?? "0,1,2,3,4"
        hiddenTabs = stored.string(forKey: "tabs.hidden") ?? ""
        tabLabels = stored.object(forKey: "tabs.labels") as? Bool ?? true
        defaultTab = stored.integer(forKey: "tabs.default")
        persistentTabs = stored.object(forKey: "tabs.persistent") as? Bool ?? true
    }
    var orderedTabs: [ShelfTab] {
        var values: [ShelfTab] = []
        for raw in tabOrder.split(separator: ",").compactMap({ Int($0) }) {
            if let tab = ShelfTab(rawValue: raw), tab != .more, !values.contains(tab) { values.append(tab) }
        }
        for tab in ShelfTab.allCases where tab != .more && !values.contains(tab) { values.append(tab) }
        return values + [.more]
    }
    var visibleTabs: [ShelfTab] {
        let hidden = Set(hiddenTabs.split(separator: ",").compactMap { Int($0) })
        return orderedTabs.filter { $0 == .more || !hidden.contains($0.rawValue) }
    }
    func isVisible(_ tab: ShelfTab) -> Bool { visibleTabs.contains(tab) }
    func setVisible(_ tab: ShelfTab, _ visible: Bool) {
        guard tab != .more else { return }
        var hidden = Set(hiddenTabs.split(separator: ",").compactMap { Int($0) })
        if visible { hidden.remove(tab.rawValue) } else { hidden.insert(tab.rawValue) }
        hiddenTabs = hidden.sorted().map(String.init).joined(separator: ",")
        if !visibleTabs.contains(where: { $0.rawValue == defaultTab }) { defaultTab = visibleTabs.first?.rawValue ?? 4 }
    }
    func moveTabs(from: IndexSet, to: Int) {
        var tabs = orderedTabs.filter { $0 != .more }
        let valid = IndexSet(from.filter { tabs.indices.contains($0) })
        tabs.move(fromOffsets: valid, toOffset: min(tabs.count, max(0, to)))
        tabOrder = (tabs + [.more]).map { String($0.rawValue) }.joined(separator: ",")
    }
    func resetTabs() {
        tabOrder = "0,1,2,3,4"; hiddenTabs = ""; tabLabels = true; defaultTab = 0
    }
    func resetAppearance() {
        palette = "default"; pureBlack = false; liquidGlass = true; blend = 10
        dateFormat = "relative"; rotation = "device"
    }
    var orientationMask: UIInterfaceOrientationMask {
        rotation == "portrait" ? .portrait : rotation == "landscape" ? .landscape : .allButUpsideDown
    }
    @MainActor func applyOrientation() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            scene.windows.first(where: \.isKeyWindow)?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: InterfaceOrientationPolicy.currentMask))
        }
    }
    func reload() {
        palette = defaults.string(forKey: "appearance.palette") ?? "default"
        pureBlack = defaults.bool(forKey: "appearance.pureBlack")
        liquidGlass = defaults.object(forKey: "appearance.liquidGlass") as? Bool ?? true
        let savedBlend = defaults.object(forKey: "appearance.blend") as? Double ?? 10
        blend = savedBlend.isFinite ? min(30, max(0, savedBlend)) : 10
        dateFormat = defaults.string(forKey: "appearance.dateFormat") ?? "relative"
        rotation = defaults.string(forKey: "appearance.rotation") ?? "device"
        tabOrder = defaults.string(forKey: "tabs.order") ?? "0,1,2,3,4"
        hiddenTabs = defaults.string(forKey: "tabs.hidden") ?? ""
        tabLabels = defaults.object(forKey: "tabs.labels") as? Bool ?? true
        defaultTab = defaults.integer(forKey: "tabs.default")
        persistentTabs = defaults.object(forKey: "tabs.persistent") as? Bool ?? true
        coverRevision = UUID()
    }
}

@MainActor enum InterfaceOrientationPolicy {
    static var readerOverride: UIInterfaceOrientationMask?
    static var currentMask: UIInterfaceOrientationMask { readerOverride ?? InterfaceState.shared.orientationMask }
}
@MainActor final class InterfaceAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        InterfaceOrientationPolicy.currentMask
    }
}

enum InterfaceDate {
    static func text(_ date: Date) -> String {
        switch InterfaceState.shared.dateFormat {
        case "short": return date.formatted(.dateTime.day().month().year().locale(L10n.language.locale))
        case "long": return date.formatted(.dateTime.day().month(.wide).year().locale(L10n.language.locale))
        case "iso":
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        default:
            if Calendar.current.isDateInToday(date) { return L10n.string("Today") }
            if Calendar.current.isDateInYesterday(date) { return L10n.string("Yesterday") }
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .wide).locale(L10n.language.locale))
        }
    }
}
