import Cocoa
import FlutterMacOS
import desktop_multi_window
import ObjectiveC.runtime

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    FieldExecPasteBridge.install()

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    
    FlutterMultiWindowPlugin.setOnWindowCreatedCallback { controller in
      RegisterGeneratedPlugins(registry: controller)
    }

    super.awakeFromNib()
  }
}

private enum FieldExecPasteBridge {
  private static var didInstall = false
  private static let channelName = "field_exec/paste"
  fileprivate static let pasteSelector = NSSelectorFromString("paste:")

  static func install() {
    if didInstall { return }
    didInstall = true
    swizzleSendActionOnNSApplication()
  }

  private static func swizzleSendActionOnNSApplication() {
    let originalSelector = #selector(NSApplication.sendAction(_:to:from:))
    let swizzledSelector = #selector(NSApplication.fieldExec_sendAction(_:to:from:))

    guard
      let originalMethod = class_getInstanceMethod(NSApplication.self, originalSelector),
      let swizzledMethod = class_getInstanceMethod(NSApplication.self, swizzledSelector)
    else {
      return
    }

    method_exchangeImplementations(originalMethod, swizzledMethod)
  }

  fileprivate static func handlePaste(window: NSWindow) -> Bool {
    let pasteboard = NSPasteboard.general
    guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return false }
    guard let controller = window.contentViewController as? FlutterViewController else { return false }

    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("pasteText", arguments: ["text": text])
    return true
  }
}

extension NSApplication {
  @objc func fieldExec_sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
    let handledByAppKit = self.fieldExec_sendAction(action, to: target, from: sender)
    if handledByAppKit { return true }

    guard action == FieldExecPasteBridge.pasteSelector else { return false }
    guard let window = self.keyWindow ?? self.mainWindow else { return false }
    return FieldExecPasteBridge.handlePaste(window: window)
  }
}
