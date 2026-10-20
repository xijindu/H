import Flutter
import UniformTypeIdentifiers
import UIKit

@MainActor
final class MediaDropBridge: NSObject, @preconcurrency UIDropInteractionDelegate {
  private let channel: FlutterMethodChannel
  private weak var attachedView: UIView?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "handy/media_drop", binaryMessenger: messenger)
    super.init()
    DispatchQueue.main.async { [weak self] in
      self?.attachToFlutterView(attempt: 0)
    }
  }

  private func attachToFlutterView(attempt: Int) {
    guard attachedView == nil else { return }
    guard let view = Self.flutterView() else {
      guard attempt < 20 else { return }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.attachToFlutterView(attempt: attempt + 1)
      }
      return
    }
    view.addInteraction(UIDropInteraction(delegate: self))
    attachedView = view
  }

  private static func flutterView() -> UIView? {
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      for window in scene.windows where !window.isHidden {
        if let controller = findFlutterController(window.rootViewController) {
          return controller.view
        }
      }
    }
    return nil
  }

  private static func findFlutterController(_ controller: UIViewController?) -> FlutterViewController? {
    guard let controller else { return nil }
    if let flutter = controller as? FlutterViewController { return flutter }
    if let navigation = controller as? UINavigationController {
      return findFlutterController(navigation.visibleViewController)
    }
    if let presented = controller.presentedViewController,
       let flutter = findFlutterController(presented) {
      return flutter
    }
    for child in controller.children {
      if let flutter = findFlutterController(child) { return flutter }
    }
    return nil
  }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
  }

  func dropInteraction(
    _ interaction: UIDropInteraction,
    sessionDidUpdate session: UIDropSession
  ) -> UIDropProposal {
    UIDropProposal(operation: .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnter session: UIDropSession) {
    channel.invokeMethod("dragEntered", arguments: nil)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
    channel.invokeMethod("dragExited", arguments: nil)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
    channel.invokeMethod("dragExited", arguments: nil)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    let providers = session.items
      .prefix(10)
      .map(\.itemProvider)
      .filter { provider in
        provider.registeredTypeIdentifiers.contains { identifier in
          UTType(identifier)?.conforms(to: .image) == true
        }
      }
    guard !providers.isEmpty else {
      channel.invokeMethod("dragExited", arguments: nil)
      return
    }

    let group = DispatchGroup()
    let lock = NSLock()
    var paths = Array<String?>(repeating: nil, count: providers.count)
    for (index, provider) in providers.enumerated() {
      guard let identifier = provider.registeredTypeIdentifiers.first(where: {
        UTType($0)?.conforms(to: .image) == true
      }) else { continue }
      group.enter()
      provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
        defer { group.leave() }
        guard let url else { return }
        let ext = Self.fileExtension(identifier: identifier, sourceURL: url)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
          "handy-drop-\(UUID().uuidString).\(ext)"
        )
        do {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: url, to: destination)
          lock.lock()
          paths[index] = destination.path
          lock.unlock()
        } catch {
          return
        }
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.channel.invokeMethod("dropImages", arguments: paths.compactMap { $0 })
    }
  }

  private static func fileExtension(identifier: String, sourceURL: URL) -> String {
    let sourceExtension = sourceURL.pathExtension.lowercased()
    if !sourceExtension.isEmpty { return sourceExtension }
    return UTType(identifier)?.preferredFilenameExtension ?? "png"
  }
}
