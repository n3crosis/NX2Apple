import SwiftUI
#if os(iOS)
import UIKit

/// The archive belongs to the caller until the activity finishes or is cancelled.
struct PackageExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Error?) -> Void

    func makeUIViewController(context: Context) -> Presenter {
        let controller = Presenter()
        controller.url = url
        controller.completion = completion
        return controller
    }
    func updateUIViewController(_ controller: Presenter, context: Context) {}

    final class Presenter: UIViewController {
        var url: URL!
        var completion: (@MainActor (Error?) -> Void)?
        private var presented = false
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            presented = true
            let activity = UIActivityViewController(activityItems: [url as Any], applicationActivities: nil)
            activity.completionWithItemsHandler = { [weak self] _, _, _, error in
                Task { @MainActor in self?.completion?(error) }
            }
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = view.bounds
            present(activity, animated: true)
        }
    }
}
#elseif os(macOS)
import AppKit

struct PackageExportShareSheet: NSViewRepresentable {
    let url: URL
    let completion: @MainActor (Error?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard view.window != nil else { coordinator.finish(nil); return }
            let picker = NSSharingServicePicker(items: [url])
            coordinator.picker = picker
            picker.delegate = coordinator
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}

    @MainActor final class Coordinator: NSObject, @MainActor NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        let completion: @MainActor (Error?) -> Void
        var picker: NSSharingServicePicker?
        private var finished = false
        init(completion: @escaping @MainActor (Error?) -> Void) { self.completion = completion }
        func finish(_ error: Error?) {
            guard !finished else { return }
            finished = true
            completion(error)
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
            if service == nil { finish(nil) }
        }
        func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }
        func sharingService(_ service: NSSharingService, didShareItems items: [Any]) { finish(nil) }
        func sharingService(_ service: NSSharingService, didFailToShareItems items: [Any], error: any Error) { finish(error) }
    }
}
#endif
