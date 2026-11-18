#if canImport(GameRuntime)
import GameRuntime
import QuartzCore
import ShellHost
import ShellUI
import GameController
import UIKit

/// Enabled only by a build that links the native runtime and embeds its build
/// identity. Source-package presence alone does not establish compatibility.
@MainActor final class NXKitGameLauncher: GamePackageLauncher {
    static let shared: NXKitGameLauncher? = {
        guard let revision = Bundle.main.object(forInfoDictionaryKey: "NXKitRuntimeRevision") as? String,
              revision.count == 40, revision.allSatisfy({ $0.isHexDigit }),
              let abi = Bundle.main.object(forInfoDictionaryKey: "NXKitRuntimeABI") as? Int, abi > 0 else { return nil }
        return NXKitGameLauncher(revision: revision, abi: abi)
    }()
    private let revision: String
    private let abi: Int
    private var controller: NXKitGameController?
    private var consumed = false
    var isGameRunning: Bool { controller != nil }

    private init(revision: String, abi: Int) { self.revision = revision; self.abi = abi }

    func checkCompatibility(_ manifest: GamePackageManifest) throws {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let current = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if targetEnvironment(macCatalyst)
        let platform = "maccatalyst"
        #else
        let platform = "ios"
        #endif
        guard manifest.runtime == "nxkit", manifest.runtimeRevision == revision,
              manifest.runtimeABI == abi, manifest.platform == platform, manifest.architecture == "arm64",
              current.compare(manifest.minOS, options: .numeric) != .orderedAscending else {
            throw GamePackageError.invalid("this game requires a different runtime build or operating system version")
        }
    }

    func launch(_ game: GamePackageLibrary.Entry, dataRoot: URL) async throws {
        try checkCompatibility(game.manifest)
        guard controller == nil, !consumed else {
            throw GamePackageError.invalid("the native runtime has already loaded a game in this process")
        }
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow),
              var presenter = window.rootViewController else { throw GameLaunchError.notAvailable }
        while let presented = presenter.presentedViewController { presenter = presented }
        let gameController = NXKitGameController()
        gameController.onClose = { [weak self] in self?.controller = nil }
        controller = gameController
        gameController.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            presenter.present(gameController, animated: true) { continuation.resume() }
        }
        consumed = true
        do {
            try await gameController.start(game: game, dataRoot: dataRoot)
        } catch {
            gameController.close()
            throw error
        }
    }
}

@MainActor private final class NXKitMetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

@MainActor private final class NXKitGameController: UIViewController {
    var onClose: (() -> Void)?
    private let surface = NXKitMetalView()
    private let controls = RuntimeTouchControls(frame: .zero)
    private var running = false
    private var closed = false
    private var stopObserver: Task<Void, Never>?
    private var touchesByID: [ObjectIdentifier: (UInt32, UITouch)] = [:]
    private var nextTouchID: UInt32 = 0
    private var observers: [NSObjectProtocol] = []
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    override func loadView() {
        view = surface
        surface.backgroundColor = .black
        surface.isMultipleTouchEnabled = true
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controls.frame = surface.bounds
        controls.onChange = { [weak self] buttons, lx, ly, rx, ry in
            guard self?.running == true else { return }
            try? GameRuntime.setPad(buttons: buttons, leftX: lx, leftY: ly, rightX: rx, rightY: ry)
        }
        controls.onClose = { [weak self] in self?.close() }
        controls.isUserInteractionEnabled = false
        surface.addSubview(controls)
        updateControls()
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateControls() }
            })
        }
        for (name, active) in [(UIApplication.didBecomeActiveNotification, true), (UIApplication.willResignActiveNotification, false)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if !active { self?.controls.reset(); self?.touchesByID.removeAll(); self?.sendTouches() }
                    if self?.running == true { try? GameRuntime.setActive(active) }
                }
            })
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = surface.window?.screen.scale ?? 1
        surface.metalLayer.contentsScale = scale
        surface.metalLayer.drawableSize = CGSize(width: surface.bounds.width * scale, height: surface.bounds.height * scale)
        if running { try? GameRuntime.resize(width: width, height: height) }
    }
    private var width: UInt32 { UInt32(max(1, surface.metalLayer.drawableSize.width)) }
    private var height: UInt32 { UInt32(max(1, surface.metalLayer.drawableSize.height)) }

    func start(game: GamePackageLibrary.Entry, dataRoot: URL) async throws {
        view.layoutIfNeeded()
        try await GameRuntime.start(root: game.runRoot, writableRoot: dataRoot, layer: surface.metalLayer,
            width: width, height: height, maximumFramesPerSecond: UInt32(surface.window?.screen.maximumFramesPerSecond ?? 60),
            adaptiveRefresh: false)
        guard !closed else { try? GameRuntime.detach(); return }
        running = true
        guard GameRuntime.state != .stopped else { close(); return }
        controls.reset()
        controls.isUserInteractionEnabled = true
        try GameRuntime.setActive(UIApplication.shared.applicationState == .active)
        stopObserver = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard self?.running == true else { return }
                if GameRuntime.state == .stopped {
                    self?.close()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
        }
    }

    private func updateControls() {
        controls.showsPad = !GCController.controllers().contains { $0.extendedGamepad != nil }
    }

    @objc func close() {
        guard !closed else { return }
        closed = true
        stopObserver?.cancel()
        stopObserver = nil
        controls.isUserInteractionEnabled = false
        controls.reset()
        if running { try? GameRuntime.detach() }
        running = false
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        dismiss(animated: true)
        onClose?()
        onClose = nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            touchesByID[ObjectIdentifier(touch)] = (nextTouchID, touch)
            nextTouchID &+= 1
        }
        sendTouches()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { sendTouches() }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches) }
    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches { touchesByID.removeValue(forKey: ObjectIdentifier(touch)) }
        sendTouches()
    }
    private func sendTouches() {
        guard running else { return }
        let width = max(1, surface.bounds.width), height = max(1, surface.bounds.height)
        let points = touchesByID.values.map { id, touch in
            let point = touch.location(in: surface)
            return GameRuntime.Touch(id: id, x: Float(min(1, max(0, point.x / width))), y: Float(min(1, max(0, point.y / height))))
        }
        try? GameRuntime.setTouches(points)
    }
}
#endif
