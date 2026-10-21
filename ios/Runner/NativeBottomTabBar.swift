import CoreText
import Flutter
import UIKit

@MainActor
final class NativeBottomTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let registrar: FlutterPluginRegistrar

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    NativeBottomTabBar(frame: frame, id: viewId, registrar: registrar, arguments: args)
  }
}

@MainActor
private final class NativeBottomTabBar: NSObject, FlutterPlatformView {
  private let host: NativeTabBarHost
  private let channel: FlutterMethodChannel

  init(frame: CGRect, id: Int64, registrar: FlutterPluginRegistrar, arguments: Any?) {
    host = NativeTabBarHost(frame: frame, registrar: registrar)
    channel = FlutterMethodChannel(
      name: "handy/native_bottom_bar/\(id)", binaryMessenger: registrar.messenger()
    )
    super.init()
    host.onSelect = { [weak self] id in self?.channel.invokeMethod("select", arguments: id) }
    host.onClearUnread = { [weak self] in self?.channel.invokeMethod("clearUnread", arguments: nil) }
    host.onHeight = { [weak self] height in self?.channel.invokeMethod("height", arguments: height) }
    if let configuration = arguments as? [String: Any] { host.update(configuration) }
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update", let configuration = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.host.update(configuration)
      result(nil)
    }
  }

  func view() -> UIView { host }

  deinit { channel.setMethodCallHandler(nil) }
}

@MainActor
private final class NativeTabBarHost: UIView, UITabBarDelegate, UIContextMenuInteractionDelegate {
  private let bar = SafeInsetTabBar()
  private let registrar: FlutterPluginRegistrar
  private var descriptors: NSArray = []
  private var lastHeight: CGFloat = 0
  private var unread = 0
  private var clearUnreadLabel = ""
  var onSelect: ((Int) -> Void)?
  var onClearUnread: (() -> Void)?
  var onHeight: ((CGFloat) -> Void)?

  init(frame: CGRect, registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    bar.delegate = self
    addSubview(bar)
    bar.addInteraction(UIContextMenuInteraction(delegate: self))
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(_ configuration: [String: Any]) {
    overrideUserInterfaceStyle = configuration["dark"] as? Bool == true ? .dark : .light
    bar.semanticContentAttribute = configuration["rtl"] as? Bool == true
      ? .forceRightToLeft : .forceLeftToRight
    bar.bottomInset = max(0, (configuration["safeBottom"] as? NSNumber)?.doubleValue ?? 0)
    if let argb = configuration["tint"] as? NSNumber {
      let value = argb.uint32Value
      bar.tintColor = UIColor(
        red: CGFloat((value >> 16) & 255) / 255,
        green: CGFloat((value >> 8) & 255) / 255,
        blue: CGFloat(value & 255) / 255,
        alpha: CGFloat((value >> 24) & 255) / 255
      )
    }
    let items = configuration["items"] as? [[String: Any]] ?? []
    if !descriptors.isEqual(to: items) {
      descriptors = items as NSArray
      bar.setItems(items.compactMap { item in
        guard let id = item["id"] as? Int, let label = item["label"] as? String else { return nil }
        return UITabBarItem(title: label, image: icon(item), tag: id)
      }, animated: false)
    }
    let selection = configuration["selection"] as? Int ?? 0
    bar.selectedItem = bar.items?.first { $0.tag == selection }
    unread = configuration["unread"] as? Int ?? 0
    clearUnreadLabel = configuration["clearUnreadLabel"] as? String ?? ""
    if let messages = bar.items?.first(where: { $0.tag == 0 }) {
      messages.badgeValue = unread > 0 ? (configuration["unreadLabel"] as? String ?? String(unread)) : nil
      messages.accessibilityCustomActions = unread > 0 ? [
        UIAccessibilityCustomAction(name: clearUnreadLabel) { [weak self] _ in
          self?.onClearUnread?()
          return true
        }
      ] : nil
    }
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let height = bar.sizeThatFits(CGSize(width: bounds.width, height: 200)).height
    bar.frame = CGRect(x: 0, y: bounds.height - height, width: bounds.width, height: height)
    if height > 0 && height != lastHeight {
      lastHeight = height
      DispatchQueue.main.async { [weak self] in self?.onHeight?(height) }
    }
  }

  func position(for bar: UIBarPositioning) -> UIBarPosition { .bottom }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    onSelect?(item.tag)
  }

  func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    guard unread > 0, let items = bar.items, !items.isEmpty else { return nil }
    let width = bar.bounds.width / CGFloat(items.count)
    let index = min(items.count - 1, max(0, Int(location.x / max(1, width))))
    let logicalIndex = bar.effectiveUserInterfaceLayoutDirection == .rightToLeft
      ? items.count - 1 - index : index
    guard items[logicalIndex].tag == 0 else { return nil }
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return nil }
      return UIMenu(children: [UIAction(title: self.clearUnreadLabel) { [weak self] _ in
        self?.onClearUnread?()
      }])
    }
  }

  private func icon(_ descriptor: [String: Any]) -> UIImage? {
    let fonts = [
      "Heroicons Solid": "solid", "Heroicons Outline": "outline",
      "Heroicons Mini": "mini", "Heroicons Micro": "micro",
    ]
    guard
      let family = descriptor["fontFamily"] as? String,
      let file = fonts[family],
      let codePoint = descriptor["codePoint"] as? Int,
      let scalar = UnicodeScalar(codePoint)
    else { return nil }
    let key = registrar.lookupKey(forAsset: "assets/fonts/heroicons-\(file).ttf", fromPackage: "heroicons_flutter")
    guard
      let path = Bundle.main.path(forResource: key, ofType: nil),
      let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
      let font = CGFont(provider),
      let name = font.postScriptName
    else { return nil }
    CTFontManagerRegisterGraphicsFont(font, nil)
    guard let uiFont = UIFont(name: name as String, size: 24) else { return nil }
    return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in
      (String(scalar) as NSString).draw(
        in: CGRect(x: 0, y: 0, width: 24, height: 24),
        withAttributes: [.font: uiFont, .foregroundColor: UIColor.black]
      )
    }.withRenderingMode(.alwaysTemplate)
  }
}

@MainActor
private final class SafeInsetTabBar: UITabBar {
  var bottomInset: CGFloat = 0
  override var safeAreaInsets: UIEdgeInsets {
    UIEdgeInsets(top: 0, left: super.safeAreaInsets.left, bottom: bottomInset, right: super.safeAreaInsets.right)
  }
}
