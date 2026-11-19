import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var systemColorsObserver: NSObjectProtocol?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "venera/system_colors", binaryMessenger: flutterViewController.engine.binaryMessenger)
    systemColorsObserver = NotificationCenter.default.addObserver(
      forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main
    ) { _ in
      channel.invokeMethod("changed", arguments: nil)
    }

    super.awakeFromNib()
  }

  deinit {
    if let observer = systemColorsObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}
