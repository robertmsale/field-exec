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
  fileprivate static let pasteAsPlainTextSelector = NSSelectorFromString("pasteAsPlainText:")
  fileprivate static let pasteAndMatchStyleSelector = NSSelectorFromString("pasteAndMatchStyle:")

  static func install() {
    if didInstall { return }
    didInstall = true
    swizzleSendActionOnNSApplication()
    swizzleInsertTextOnNSTextView()
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

  private static func swizzleInsertTextOnNSTextView() {
    let originalSelector = #selector(NSTextView.insertText(_:replacementRange:))
    let swizzledSelector = #selector(NSTextView.fieldExec_insertText(_:replacementRange:))

    guard
      let originalMethod = class_getInstanceMethod(NSTextView.self, originalSelector),
      let swizzledMethod = class_getInstanceMethod(NSTextView.self, swizzledSelector)
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

  fileprivate static func handleInsertText(window: NSWindow, text: String) -> Bool {
    guard !text.isEmpty else { return false }
    guard let controller = window.contentViewController as? FlutterViewController else { return false }

    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.invokeMethod("insertText", arguments: ["text": text])
    return true
  }
}

extension NSApplication {
  @objc func fieldExec_sendAction(_ action: Selector, to target: Any?, from sender: Any?) -> Bool {
    if action == FieldExecPasteBridge.pasteSelector ||
        action == FieldExecPasteBridge.pasteAsPlainTextSelector ||
        action == FieldExecPasteBridge.pasteAndMatchStyleSelector {
      if let window = self.keyWindow ?? self.mainWindow,
         FieldExecPasteBridge.handlePaste(window: window) {
        // Treat as handled so Dictation/paste flows don't depend on Flutter/AppKit's responder chain.
        return true
      }
    }

    return self.fieldExec_sendAction(action, to: target, from: sender)
  }
}

extension NSTextView {
  @objc func fieldExec_insertText(_ insertString: Any, replacementRange: NSRange) {
    // Only intercept “non-event” insertions (common for accessibility-driven apps).
    // Avoid double-inserting for normal typing, IME, etc.
    if NSApp.currentEvent == nil {
      let text: String? = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
      if let text = text,
         let window = self.window ?? NSApp.keyWindow ?? NSApp.mainWindow {
        _ = FieldExecPasteBridge.handleInsertText(window: window, text: text)
      }
    }

    // Call the original implementation (which is now swapped).
    self.fieldExec_insertText(insertString, replacementRange: replacementRange)
  }
}
