import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

}

/// Reads the traits of the view hosting this Flutter scene. A global screen or
/// device-orientation check cannot identify the correct edge in Split View.
final class PlayOnConViewController: FlutterViewController {
  private var layoutChannel: FlutterEventChannel?
  private var layoutBridge: AppleLayoutBridge?

  override func viewDidLoad() {
    super.viewDidLoad()
    let bridge = AppleLayoutBridge(viewController: self)
    let channel = FlutterEventChannel(
      name: "playoncon/apple_layout", binaryMessenger: binaryMessenger)
    channel.setStreamHandler(bridge)
    layoutBridge = bridge
    layoutChannel = channel

    if #available(iOS 27.1, *) {
      registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
        (controller: PlayOnConViewController, _: UITraitCollection) in
        controller.layoutBridge?.publish()
      }
      registerForTraitChanges([UITraitLayoutDirection.self]) {
        (controller: PlayOnConViewController, _: UITraitCollection) in
        controller.layoutBridge?.publish()
      }
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Re-query reserved regions as the window resizes, folds, or its camera
    // becomes active. Frames are relative to the same view Flutter renders in.
    layoutBridge?.publish()
  }

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    layoutBridge?.publish()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    layoutBridge?.publish()
  }
}

private final class AppleLayoutBridge: NSObject, FlutterStreamHandler {
  private weak var viewController: UIViewController?
  private var eventSink: FlutterEventSink?
  private var lastSnapshot: NSDictionary?

  init(viewController: UIViewController) {
    self.viewController = viewController
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    eventSink = events
    lastSnapshot = nil
    publish()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    lastSnapshot = nil
    return nil
  }

  func publish() {
    guard let eventSink, let controller = viewController, controller.isViewLoaded else { return }
    let view = controller.view!
    var snapshot: [String: Any] = [
      "barEdge": "unavailable",
      "viewWidth": Double(view.bounds.width),
      "viewHeight": Double(view.bounds.height),
      "occlusions": [],
      "divisions": [],
    ]
    if #available(iOS 27.1, *), view.window != nil {
      let traits = controller.traitCollection
      let isRTL = traits.layoutDirection == .rightToLeft
      switch traits.verticalBarEdge {
      case .leading: snapshot["barEdge"] = isRTL ? "right" : "left"
      case .trailing: snapshot["barEdge"] = isRTL ? "left" : "right"
      case .unspecified: snapshot["barEdge"] = "none"
      @unknown default: snapshot["barEdge"] = "unavailable"
      }
      // Frames already include the system's interaction margins. Keep these
      // physical view coordinates; Dart must not mirror them in RTL or add the
      // margins a second time. Flutter supplies normal safe-area insets itself.
      snapshot["occlusions"] = regions(in: view, kind: .occlusion)
      snapshot["divisions"] = regions(in: view, kind: .division)
    }
    let value = snapshot as NSDictionary
    guard lastSnapshot?.isEqual(value) != true else { return }
    lastSnapshot = value
    eventSink(snapshot)
  }

  @available(iOS 27.1, *)
  private func regions(in view: UIView, kind: UIView.ReservedRegion.Kind) -> [[String: Double]] {
    view.reservedRegions(kind: kind).filter(\.isActive).map { region in
      [
        "left": Double(region.frame.minX),
        "top": Double(region.frame.minY),
        "width": Double(region.frame.width),
        "height": Double(region.frame.height),
      ]
    }
  }
}
