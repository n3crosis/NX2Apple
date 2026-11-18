import AVFAudio
import CGameRuntime
import Foundation
import QuartzCore

/// A single game in this process. Detaching does not unload or reset the runtime.
/// Link with the iOS libnxkit_host.a built from the runtime port.
@MainActor
public enum GameRuntime {
    private static var started = false
    private static var active = true
    private static var detached = false
    private static var interruptionObserver: NSObjectProtocol?

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    public struct Touch {
        public let id: UInt32
        public let x: Float
        public let y: Float

        public init(id: UInt32, x: Float, y: Float) {
            self.id = id
            self.x = x
            self.y = y
        }
    }

    public enum State { case detached, attached, stopped }

    public static var state: State {
        switch nxkit_ios_state() {
        case 1: .attached
        case 2: .stopped
        default: .detached
        }
    }

    /// root contains game.json. Its native library must already have an accepted signature.
    /// writableRoot is device-local save/cache storage, outside the distributable payload.
    /// A failed launch can consume the process-scoped runtime. Restart before retrying.
    public static func start(root: URL, writableRoot: URL, layer: CAMetalLayer,
                             width: UInt32, height: UInt32,
                             maximumFramesPerSecond: UInt32, adaptiveRefresh: Bool) async throws {
        guard root.isFileURL, writableRoot.isFileURL else {
            throw Failure(message: "Game paths must be local folders.")
        }
        guard !started else {
            throw Failure(message: "Restart the app before starting another game.")
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playback, mode: .default)
        try audio.setActive(true)
        started = true
        observeAudioInterruptions()
        do {
            try await Task.detached {
                try root.path.withCString { path in
                    try writableRoot.path.withCString { writable in
                        try check { nxkit_ios_prepare(path, writable, $0, $1) }
                    }
                }
            }.value
            try Task.checkCancellation()
            guard !detached else { throw CancellationError() }
            try check { error, capacity in
                nxkit_ios_attach(Unmanaged.passUnretained(layer).toOpaque(), width, height,
                                 maximumFramesPerSecond, adaptiveRefresh ? 1 : 0, error, capacity)
            }
        } catch {
            try? detach()
            throw error
        }
    }

    /// Nintendo button bits 0...15. Stick axes range from -1 to 1, with positive y up.
    public static func setPad(buttons: UInt64, leftX: Float, leftY: Float,
                              rightX: Float, rightY: Float) throws {
        try check { nxkit_ios_set_pad(buttons, leftX, leftY, rightX, rightY, $0, $1) }
    }

    public static func resize(width: UInt32, height: UInt32) throws {
        try check { nxkit_ios_resize(width, height, $0, $1) }
    }

    public static func setActive(_ active: Bool) throws {
        self.active = active
        let presentation = Result { try check { nxkit_ios_set_active(active ? 1 : 0, $0, $1) } }
        let audio = Result { try setAudioActive(active) }
        try presentation.get()
        try audio.get()
    }

    public static func setTouches(_ touches: [Touch]) throws {
        let points = touches.map { NXKitTouch(id: $0.id, x: $0.x, y: $0.y) }
        try points.withUnsafeBufferPointer { buffer in
            try check { nxkit_ios_set_touches(buffer.baseAddress, buffer.count, $0, $1) }
        }
    }

    /// Releases presentation only. Guest state remains allocated until the process ends.
    public static func detach() throws {
        active = false
        detached = true
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        let presentation = Result { try check { nxkit_ios_detach($0, $1) } }
        let audio = Result { try setAudioActive(false) }
        try presentation.get()
        try audio.get()
    }

    private static func setAudioActive(_ active: Bool) throws {
        if active {
            try AVAudioSession.sharedInstance().setActive(true)
            try check { nxkit_ios_set_audio_paused(0, $0, $1) }
        } else {
            let pause = Result { try check { nxkit_ios_set_audio_paused(1, $0, $1) } }
            let deactivate = Result {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
            try pause.get()
            try deactivate.get()
        }
    }

    private static func observeAudioInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard interruptionObserver != nil else { return }
                do {
                    if type == AVAudioSession.InterruptionType.began.rawValue {
                        try check { nxkit_ios_set_audio_paused(1, $0, $1) }
                    } else if type == AVAudioSession.InterruptionType.ended.rawValue,
                              active,
                              AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                        try AVAudioSession.sharedInstance().setActive(true)
                        try check { nxkit_ios_set_audio_paused(0, $0, $1) }
                    }
                } catch {
                    NSLog("Game audio interruption: %@", error.localizedDescription)
                }
            }
        }
    }

    nonisolated private static func check(_ call: (UnsafeMutablePointer<CChar>, Int) -> Int32) throws {
        var error = [CChar](repeating: 0, count: 1024)
        let result = error.withUnsafeMutableBufferPointer { buffer in
            call(buffer.baseAddress!, buffer.count)
        }
        if result != 0 {
            throw Failure(message: error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
    }
}
