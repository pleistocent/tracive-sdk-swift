#if os(iOS)
  import UIKit

  /// Where the "Open in" sheet is presented from. On iPhone it is an action sheet either way; on
  /// iPad it is a popover, and this is what its arrow points at.
  public enum ReportFormAnchor {
    /// The control the user tapped, usually the Report button.
    case view(UIView)
    /// A view controller's view, with the popover pointing at `sourceView` inside it.
    case viewController(UIViewController, sourceView: UIView)
    case barButtonItem(UIBarButtonItem)
    /// The top view controller of the key window, with the popover pointing at its centre. For
    /// SwiftUI and other callers with no `UIView` to hand.
    case keyWindow
  }

  /// `UIDocumentInteractionController.presentOpenInMenu`, reported through `OpenInMenuResolution`.
  @MainActor
  final class DocumentInteractionMenuPresenter: NSObject, OpenInMenuPresenting {

    private let anchor: ReportFormAnchor
    private var controller: UIDocumentInteractionController?
    private var resolution: OpenInMenuResolution?
    private var sheetCheck: Timer?
    /// Holds this object, and through it the controller, until the hand-over ends. The caller lets
    /// go as soon as `willBegin` settles the answer, while iOS is still copying the file; the
    /// controller only holds its delegate weakly.
    private var keepAlive: DocumentInteractionMenuPresenter?

    init(anchor: ReportFormAnchor) {
      self.anchor = anchor
    }

    func presentOpenInMenu(for file: URL) async -> OpenInMenuOutcome {
      await withCheckedContinuation { continuation in
        let resolution = OpenInMenuResolution { continuation.resume(returning: $0) }
        self.resolution = resolution

        let controller = UIDocumentInteractionController(url: file)
        controller.delegate = self
        self.controller = controller

        keepAlive = self
        if let failure = present(controller) {
          resolution.notPresented(reason: failure)
          release()
        }
      }
    }

    /// `nil` when the sheet is up, otherwise why it is not.
    private func present(_ controller: UIDocumentInteractionController) -> String? {
      let window: UIWindow?
      let show: () -> Bool
      switch anchor {
      case .view(let view):
        guard view.window != nil else { return "anchor_not_in_window" }
        window = view.window
        show = { controller.presentOpenInMenu(from: view.bounds, in: view, animated: true) }
      case .viewController(let viewController, let sourceView):
        guard let host = viewController.viewIfLoaded, host.window != nil else {
          return "anchor_not_in_window"
        }
        window = host.window
        let rect = sourceView.convert(sourceView.bounds, to: host)
        show = { controller.presentOpenInMenu(from: rect, in: host, animated: true) }
      case .barButtonItem(let item):
        window = Self.keyWindow()
        show = { controller.presentOpenInMenu(from: item, animated: true) }
      case .keyWindow:
        guard let host = Self.topViewController(of: Self.keyWindow())?.viewIfLoaded else {
          return "no_presenting_view"
        }
        window = host.window
        let centre = CGRect(x: host.bounds.midX, y: host.bounds.midY, width: 1, height: 1)
        show = { controller.presentOpenInMenu(from: centre, in: host, animated: true) }
      }
      let topBefore = Self.topViewController(of: window)
      guard show() else { return "menu_not_presented" }
      watchForSheet(in: window, above: topBefore)
      return nil
    }

    private func watchForSheet(in window: UIWindow?, above topBefore: UIViewController?) {
      // `presentOpenInMenu` returns before the sheet is presented, so it is looked for on each check.
      weak var window = window
      weak var topBefore = topBefore
      weak var sheet: UIViewController?
      var seen = false
      let watch = VanishedSheetWatch(
        isGone: {
          guard seen else {
            if let top = Self.topViewController(of: window), top !== topBefore {
              sheet = top
              seen = true
            }
            return false
          }
          return sheet?.presentingViewController == nil
        },
        onVanished: { [weak self] in
          self?.sheetCheck?.invalidate()
          self?.resolution?.didDismissMenu()
          self?.releaseIfFinished()
        })
      sheetCheck = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        MainActor.assumeIsolated { watch.check() }
      }
    }

    private static func keyWindow() -> UIWindow? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      return scenes.first { $0.activationState == .foregroundActive }?.keyWindow
        ?? scenes.lazy.flatMap(\.windows).first { $0.isKeyWindow }
    }

    private static func topViewController(of window: UIWindow?) -> UIViewController? {
      var top = window?.rootViewController
      while let presented = top?.presentedViewController, !presented.isBeingDismissed {
        top = presented
      }
      return top
    }

    private func releaseIfFinished() {
      if resolution?.isFinished == true { release() }
    }

    private func release() {
      sheetCheck?.invalidate()
      sheetCheck = nil
      controller?.delegate = nil
      controller = nil
      resolution = nil
      keepAlive = nil
    }

    // MARK: - UIDocumentInteractionControllerDelegate
    //
    // `@objc` spelled out: these are optional requirements, so a witness the compiler did not
    // expose to the Objective-C runtime is never called, and the call would wait forever.

    @objc func documentInteractionController(
      _ controller: UIDocumentInteractionController,
      willBeginSendingToApplication application: String?
    ) {
      resolution?.willBeginSending(toApplication: application)
      releaseIfFinished()
    }

    @objc func documentInteractionControllerDidDismissOpenInMenu(
      _ controller: UIDocumentInteractionController
    ) {
      resolution?.didDismissMenu()
      releaseIfFinished()
    }

    @objc func documentInteractionController(
      _ controller: UIDocumentInteractionController,
      didEndSendingToApplication application: String?
    ) {
      resolution?.didEndSending(toApplication: application)
      releaseIfFinished()
    }
  }

  // UIKit does not mark this protocol main-actor, though it only ever calls it on the main thread.
  // `@preconcurrency` states that and checks it at run time; Swift 5 compilers cannot parse it.
  #if compiler(>=6.0)
    extension DocumentInteractionMenuPresenter:
      @preconcurrency UIDocumentInteractionControllerDelegate
    {}
  #else
    extension DocumentInteractionMenuPresenter: UIDocumentInteractionControllerDelegate {}
  #endif
#endif
