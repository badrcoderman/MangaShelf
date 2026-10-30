import SwiftUI
import UIKit
import ReaderCore

/// All model mutations check this gate. The generation also rejects source
/// requests that started before a restore and finish after it has ended.
@MainActor final class BackupMaintenance: ObservableObject {
    static let shared = BackupMaintenance()
    @Published private(set) var isActive = false
    @Published private(set) var generation: UInt64 = 0
    @Published private(set) var status = ""
    @Published private(set) var canCancel = false
    private var owner: UUID?
    private var cancellation: (() -> Void)?
    private init() {}
    func begin(_ label: String, cancel: (() -> Void)? = nil) throws -> UUID {
        guard owner == nil else { throw ReaderFailure(L10n.string("Another library operation is still running.")) }
        let token = UUID(); owner = token
        generation &+= 1; status = label; isActive = true
        cancellation = cancel; canCancel = cancel != nil
        return token
    }
    func update(_ label: String, owner token: UUID, cancellable: Bool) {
        guard owner == token else { return }
        status = label; canCancel = cancellable && cancellation != nil
    }
    func end(_ token: UUID) {
        guard owner == token else { return }
        cancellation = nil; canCancel = false; status = ""; owner = nil; isActive = false
    }
    func cancel() {
        guard isActive, canCancel else { return }
        canCancel = false; status = L10n.string("Canceling…"); cancellation?()
    }
}

/// A separate window blocks interaction with sheets and readers as well as the
/// root tabs while immutable snapshots or an atomic restore are being prepared.
struct BackupMaintenanceWindowShield: UIViewRepresentable {
    @ObservedObject var maintenance: BackupMaintenance
    func makeCoordinator() -> Coordinator { Coordinator(maintenance: maintenance) }
    func makeUIView(context: Context) -> Anchor {
        let view = Anchor(); view.isUserInteractionEnabled = false
        view.didAttach = { [weak coordinator = context.coordinator] window in coordinator?.window = window; coordinator?.render() }
        return view
    }
    func updateUIView(_ view: Anchor, context: Context) { context.coordinator.render() }
    static func dismantleUIView(_ view: Anchor, coordinator: Coordinator) { coordinator.remove() }
    final class Anchor: UIView {
        var didAttach: ((UIWindow?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); didAttach?(window) }
    }
    @MainActor final class Coordinator: NSObject {
        let maintenance: BackupMaintenance
        weak var window: UIWindow?
        private var shield: UIWindow?
        private weak var statusLabel: UILabel?
        private weak var cancelButton: UIButton?
        init(maintenance: BackupMaintenance) { self.maintenance = maintenance }
        @objc private func cancel() { maintenance.cancel() }
        func remove() { shield?.isHidden = true; shield = nil; statusLabel = nil; cancelButton = nil }
        func render() {
            guard maintenance.isActive, let window, let scene = window.windowScene else { remove(); return }
            if let shield, shield.windowScene === scene {
                statusLabel?.text = maintenance.status
                cancelButton?.isHidden = !maintenance.canCancel
                return
            }
            remove()
            let controller = UIViewController()
            let surface = UIView(); surface.backgroundColor = UIColor(ShelfStyle.background)
            surface.accessibilityViewIsModal = true; controller.view = surface
            let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 20; stack.alignment = .center
            stack.translatesAutoresizingMaskIntoConstraints = false
            let spinner = UIActivityIndicatorView(style: .large); spinner.color = UIColor(ShelfStyle.accent)
            spinner.startAnimating(); stack.addArrangedSubview(spinner)
            let label = UILabel(); label.text = maintenance.status; label.numberOfLines = 0
            label.textAlignment = .center; label.font = .preferredFont(forTextStyle: .headline)
            label.adjustsFontForContentSizeCategory = true; label.textColor = UIColor(ShelfStyle.text)
            stack.addArrangedSubview(label); statusLabel = label
            let button = UIButton(type: .system); button.setTitle(L10n.string("Cancel"), for: .normal)
            button.titleLabel?.font = .preferredFont(forTextStyle: .body); button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.tintColor = UIColor(ShelfStyle.accent); button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addTarget(self, action: #selector(cancel), for: .touchUpInside); button.isHidden = !maintenance.canCancel
            stack.addArrangedSubview(button); cancelButton = button
            surface.addSubview(stack)
            NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: surface.centerXAnchor), stack.centerYAnchor.constraint(equalTo: surface.centerYAnchor), stack.widthAnchor.constraint(lessThanOrEqualTo: surface.widthAnchor, constant: -48)])
            let cover = UIWindow(windowScene: scene)
            cover.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
            cover.rootViewController = controller; cover.isHidden = false; shield = cover
        }
    }
}
