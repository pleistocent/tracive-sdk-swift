import SwiftUI
import UIKit

/// The one way both screens are shown, from UIKit, SwiftUI, Flutter or React Native.
final class ReportModalHost<Content: View>: UIHostingController<Content> {
  var onClosed: (() -> Void)?

  private var shown = false
  private var closeRequested = false

  /// A user with no grant is refused within milliseconds of the form opening, while it still
  /// animates in. UIKit can ignore a dismiss at that moment, which would leave them on a spinner.
  func close() {
    if shown {
      dismiss(animated: true)
    } else {
      closeRequested = true
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    shown = true
    if closeRequested { dismiss(animated: true) }
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // In iPhone landscape a picker covers the form full screen, which also lands here. That is not
    // a close, so SwiftUI's onDisappear would cancel the upload and lose the form.
    guard presentedViewController == nil, isBeingDismissed || presentingViewController == nil
    else { return }
    let closed = onClosed
    onClosed = nil
    closed?()
  }
}

struct ReportModalPresenter: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let makeHost: (_ onFinished: @escaping () -> Void) -> UIViewController

  func makeUIViewController(context: Context) -> ReportModalAnchor {
    ReportModalAnchor()
  }

  func updateUIViewController(_ anchor: ReportModalAnchor, context: Context) {
    anchor.isWanted = isPresented
    anchor.makeHost = makeHost
    let binding = $isPresented
    anchor.onFinished = { binding.wrappedValue = false }
    anchor.sync()
  }
}

final class ReportModalAnchor: UIViewController {
  var isWanted = false
  var makeHost: ((_ onFinished: @escaping () -> Void) -> UIViewController)?
  var onFinished: (() -> Void)?

  private var host: UIViewController?

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    sync()
  }

  func sync() {
    if isWanted, host == nil, viewIfLoaded?.window != nil, let makeHost {
      let host = makeHost { [weak self] in
        self?.host = nil
        self?.onFinished?()
      }
      self.host = host
      // Presenting mid-update trips "modifying state during view update" in the host's body.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        top.present(host, animated: true)
      }
    } else if !isWanted, let host, host.presentingViewController != nil, !host.isBeingDismissed {
      host.dismiss(animated: true)
    }
  }
}
