import SwiftUI
import LocalAuthentication
import UIKit

@MainActor final class AppPrivacy: ObservableObject {
    @Published private(set) var lockEnabled: Bool
    @Published private(set) var locked: Bool
    @Published private(set) var authenticating = false
    @Published var error: String?
    @Published var lockInterval: Int { didSet { UserDefaults.standard.set(lockInterval, forKey: "privacy.lockInterval") } }
    @Published var hideAppSwitcher: Bool { didSet { UserDefaults.standard.set(hideAppSwitcher, forKey: "privacy.hideAppSwitcher") } }
    private var backgroundedAt: Date?
    private var inBackground = false
    private var context: LAContext?
    private var generation = UUID()
    init() {
        let defaults = UserDefaults.standard
        let enabled = defaults.bool(forKey: "privacy.lockEnabled")
        lockEnabled = enabled; locked = enabled
        lockInterval = max(0, min(300, defaults.integer(forKey: "privacy.lockInterval")))
        hideAppSwitcher = defaults.bool(forKey: "privacy.hideAppSwitcher")
    }
    func sceneChanged(_ phase: ScenePhase) async {
        switch phase {
        case .background:
            inBackground = true; backgroundedAt = Date()
            generation = UUID(); context?.invalidate(); context = nil; authenticating = false
            if lockEnabled && lockInterval == 0 { locked = true }
        case .active:
            inBackground = false
            if lockEnabled, let date = backgroundedAt, Date().timeIntervalSince(date) >= Double(lockInterval) { locked = true }
            backgroundedAt = nil
            if lockEnabled && locked { await unlock() }
        default: break
        }
    }
    func setLockEnabled(_ enabled: Bool) async {
        guard enabled != lockEnabled, !authenticating else { return }
        guard await authenticate() else { return }
        lockEnabled = enabled; locked = false
        UserDefaults.standard.set(enabled, forKey: "privacy.lockEnabled")
    }
    func unlock() async {
        guard lockEnabled, locked, !authenticating, !inBackground else { return }
        if await authenticate() { locked = false }
    }
    private func authenticate() async -> Bool {
        let attempt = UUID(); generation = attempt
        let local = LAContext(); context = local
        var unavailable: NSError?
        guard local.canEvaluatePolicy(.deviceOwnerAuthentication, error: &unavailable) else {
            error = L10n.string("Device authentication is unavailable. Set a device passcode and try again.")
            context = nil; return false
        }
        authenticating = true; error = nil
        do {
            let accepted = try await local.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: L10n.string("Unlock your MangaShelf library"))
            guard generation == attempt, !inBackground else { return false }
            authenticating = false; context = nil
            return accepted
        } catch {
            guard generation == attempt else { return false }
            authenticating = false; context = nil
            if !inBackground { self.error = L10n.string("Authentication was not completed. Try again to unlock.") }
            return false
        }
    }
}

struct AppLockedView: View {
    @ObservedObject var privacy: AppPrivacy
    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "lock.fill").font(.system(size: 42)).accessibilityHidden(true)
            Text(L10n.string("MangaShelf is locked")).shelfFont(.title2)
            if let error = privacy.error { Text(error).shelfFont(.subheadline).multilineTextAlignment(.center) }
            Button(L10n.string("Unlock")) { Task { await privacy.unlock() } }
                .buttonStyle(ShelfPrimaryButtonStyle()).disabled(privacy.authenticating)
                .accessibilityIdentifier("privacy.unlock")
            if privacy.authenticating { ProgressView() }
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(ShelfStyle.text).background(ShelfStyle.background.ignoresSafeArea())
            .accessibilityAddTraits(.isModal)
    }
}

/// A window-level cover also protects any sheets or reader presented over RootView.
/// It is installed synchronously before UIKit takes the app-switcher snapshot.
struct AppPrivacyWindowShield: UIViewRepresentable {
    @ObservedObject var privacy: AppPrivacy
    func makeCoordinator() -> Coordinator { Coordinator(privacy: privacy) }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor(); view.isUserInteractionEnabled = false
        view.didAttach = { [weak coordinator = context.coordinator] window in coordinator?.window = window; coordinator?.render() }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { context.coordinator.privacy = privacy; context.coordinator.render() }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.remove() }
    final class Anchor: UIView {
        var didAttach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); didAttach?(window) }
    }
    @MainActor final class Coordinator: NSObject {
        var privacy: AppPrivacy
        weak var window: UIWindow?
        private var inactive = UIApplication.shared.applicationState != .active
        private var coverWindow: UIWindow?
        init(privacy: AppPrivacy) {
            self.privacy = privacy; super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(resigning), name: UIApplication.willResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(active), name: UIApplication.didBecomeActiveNotification, object: nil)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc private func resigning() { inactive = true; render() }
        @objc private func active() { inactive = false; render() }
        @objc private func unlock() { Task { await privacy.unlock() } }
        func remove() { coverWindow?.isHidden = true; coverWindow = nil }
        func render() {
            remove()
            guard let window, let scene = window.windowScene,
                  privacy.locked || (inactive && (privacy.hideAppSwitcher || privacy.lockEnabled)) else { return }
            let surface = UIView(frame: window.bounds)
            surface.backgroundColor = UIColor(ShelfStyle.background)
            surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            surface.accessibilityViewIsModal = true
            let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 20; stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            let icon = UIImageView(image: UIImage(systemName: "lock.fill")); icon.tintColor = UIColor(ShelfStyle.secondary)
            icon.contentMode = .scaleAspectFit; icon.widthAnchor.constraint(equalToConstant: 42).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 48).isActive = true; stack.addArrangedSubview(icon)
            let label = UILabel(); label.text = privacy.locked ? L10n.string("MangaShelf is locked") : "MangaShelf"
            label.textColor = UIColor(ShelfStyle.text); label.font = .preferredFont(forTextStyle: .title2)
            label.adjustsFontForContentSizeCategory = true; label.numberOfLines = 0; label.textAlignment = .center
            stack.addArrangedSubview(label)
            if privacy.locked {
                if let error = privacy.error {
                    let message = UILabel(); message.text = error; message.numberOfLines = 0
                    message.font = .preferredFont(forTextStyle: .subheadline); message.adjustsFontForContentSizeCategory = true
                    message.textColor = UIColor(ShelfStyle.secondary); message.textAlignment = .center; stack.addArrangedSubview(message)
                }
                let button = UIButton(type: .system); button.setTitle(L10n.string("Unlock"), for: .normal)
                button.titleLabel?.font = .preferredFont(forTextStyle: .headline); button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.tintColor = UIColor(ShelfStyle.accent); button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
                button.isEnabled = !privacy.authenticating; button.accessibilityIdentifier = "privacy.unlock.window"
                button.addTarget(self, action: #selector(unlock), for: .touchUpInside); stack.addArrangedSubview(button)
            }
            surface.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: surface.centerXAnchor), stack.centerYAnchor.constraint(equalTo: surface.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, constant: -48)])
            // A separate window stays above sheets/alerts presented after locking.
            let shield = UIWindow(windowScene: scene)
            shield.frame = window.bounds
            shield.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
            let controller = UIViewController(); controller.view = surface
            shield.rootViewController = controller; shield.isHidden = false
            coverWindow = shield
        }
    }
}
