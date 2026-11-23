
// Kanal "junels/files": PDF-Text lesen (PDFKit), Dateien öffnen, im Finder zeigen, teilen.
enum JunelsFiles {
  static func notifyStyle(_ kind: String) -> (label: String, symbol: String, color: NSColor, loud: Bool) {
    switch kind {
    case "aktion": return ("Aktion", "hand.tap.fill", NSColor(srgbRed: 0.49, green: 0.31, blue: 0.88, alpha: 1), true)
    case "warnung": return ("Warnung", "exclamationmark.triangle.fill", NSColor(srgbRed: 0.82, green: 0.27, blue: 0.27, alpha: 1), true)
    case "erinnerung": return ("Erinnerung", "alarm.fill", NSColor(srgbRed: 0.72, green: 0.53, blue: 0.04, alpha: 1), true)
    case "ergebnis": return ("Fertig", "checkmark.circle.fill", NSColor(srgbRed: 0.07, green: 0.60, blue: 0.40, alpha: 1), false)
    case "ruhig": return ("Hintergrund", "arrow.triangle.2.circlepath", NSColor.gray, false)
    default: return ("Info", "info.circle.fill", NSColor(srgbRed: 0.18, green: 0.42, blue: 0.85, alpha: 1), false)
    }
  }

  /// Farbiger Kreis mit weißem SF-Symbol als PNG (Bild in der Mitteilung). Jedes Mal neu (Anhänge werden verschoben).
  static func badge(symbol: String, color: NSColor, kind: String) -> URL? {
    guard #available(macOS 11.0, *),
          let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 44, weight: .semibold)) else { return nil }
    let size = NSSize(width: 96, height: 96)
    let img = NSImage(size: size)
    img.lockFocus()
    color.setFill()
    NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
    let tinted = NSImage(size: sym.size)
    tinted.lockFocus()
    sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let r = NSRect(x: (size.width - sym.size.width) / 2, y: (size.height - sym.size.height) / 2,
                   width: sym.size.width, height: sym.size.height)
    tinted.draw(in: r)
    img.unlockFocus()
    guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else { return nil }
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("junels-\(kind)-\(UUID().uuidString).png")
    do { try data.write(to: url) } catch { return nil }
    return url
  }

  static func register(_ controller: FlutterViewController) {
    JunelsNotifyDelegate.install()
    let channel = FlutterMethodChannel(name: "junels/files", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      let path = args["path"] as? String ?? ""
      let url = URL(fileURLWithPath: path)
      switch call.method {
      case "openUrl":
        if let s = args["url"] as? String, let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
          result(NSWorkspace.shared.open(u))
        } else {
          result(false)
        }
      case "pdfText":
        DispatchQueue.global(qos: .userInitiated).async {
          guard let doc = PDFDocument(url: url) else {
            DispatchQueue.main.async { result(FlutterError(code: "pdf", message: "PDF konnte nicht geöffnet werden", details: nil)) }
            return
          }
          if doc.isLocked {
            DispatchQueue.main.async { result(FlutterError(code: "pdf", message: "PDF ist passwortgeschützt", details: nil)) }
            return
          }
          let maxPages = min(doc.pageCount, args["maxPages"] as? Int ?? 300)
          var text = ""
          for i in 0..<maxPages {
            if let page = doc.page(at: i), let s = page.string { text += s + "\n\n" }
          }
          DispatchQueue.main.async { result(["text": text, "pages": doc.pageCount]) }
        }
      case "pdfPages":
        // Seiten als PNG (Vorschau zum Durchblättern)
        DispatchQueue.global(qos: .userInitiated).async {
          guard let doc = PDFDocument(url: url), !doc.isLocked else {
            DispatchQueue.main.async { result(FlutterError(code: "pdf", message: "PDF konnte nicht geöffnet werden", details: nil)) }
            return
          }
          let outDir = args["out"] as? String ?? NSTemporaryDirectory()
          let width = CGFloat(args["width"] as? Int ?? 960)
          try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
          var paths: [String] = []
          let count = min(doc.pageCount, args["maxPages"] as? Int ?? 60)
          for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let size = NSSize(width: width, height: width * box.height / max(box.width, 1))
            let img = page.thumbnail(of: size, for: .mediaBox)
            guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            let p = (outDir as NSString).appendingPathComponent("seite-\(i + 1).png")
            if (try? png.write(to: URL(fileURLWithPath: p))) != nil { paths.append(p) }
          }
          DispatchQueue.main.async { result(paths) }
        }
      case "notify":
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
          guard granted else { return }
          let content = UNMutableNotificationContent()
          content.title = args["title"] as? String ?? "Junels"
          content.body = args["body"] as? String ?? ""
          // Art der Meldung: Untertitel, Ton, Unterbrechung, farbiges Symbol (Konzept „Benachrichtigungen“)
          let kind = args["kind"] as? String ?? "info"
          let style = JunelsFiles.notifyStyle(kind)
          content.subtitle = style.label
          content.threadIdentifier = "junels-\(kind)"
          if style.loud { content.sound = .default }
          if #available(macOS 12.0, *) {
            content.interruptionLevel = (kind == "info" || kind == "ruhig") ? .passive : .active
          }
          if let png = JunelsFiles.badge(symbol: style.symbol, color: style.color, kind: kind),
             let att = try? UNNotificationAttachment(identifier: "art", url: png, options: nil) {
            content.attachments = [att]
          }

          var trigger: UNNotificationTrigger? = nil
          if let at = args["at"] as? NSNumber {
            let secs = at.doubleValue / 1000 - Date().timeIntervalSince1970
            if secs > 1 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false) }
          }
          var info: [String: Any] = ["kind": kind]
          if let target = args["conversation"] as? String { info["target"] = target }
          content.userInfo = info
          if kind == "erinnerung" { content.categoryIdentifier = "junels.reminder" }
          let ident = (args["id"] as? NSNumber).map { "junels-\($0.intValue)" } ?? UUID().uuidString
          center.add(UNNotificationRequest(identifier: ident, content: content, trigger: trigger))
        }
        result(true)
      case "cancelNotify":
        if let id = args["id"] as? NSNumber {
          let ident = "junels-\(id.intValue)"
          UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [ident])
          UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [ident])
        }
        result(true)
      case "takeNotifyEvents":
        let d = UserDefaults.standard
        let ev = d.array(forKey: "junels.notifyEvents") ?? []
        d.set([], forKey: "junels.notifyEvents")
        result(ev)
      case "open":
        result(NSWorkspace.shared.open(url))
      case "reveal":
        NSWorkspace.shared.activateFileViewerSelecting([url])
        result(true)
      case "share":
        let picker = NSSharingServicePicker(items: [url])
        let view = controller.view
        let rect = NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        result(true)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Mitteilungen: auch bei offener App zeigen; Erinnerungen mit „Schlummern“ und „Erledigt“.
final class JunelsNotifyDelegate: NSObject, UNUserNotificationCenterDelegate {
  static let shared = JunelsNotifyDelegate()

  static func install() {
    let center = UNUserNotificationCenter.current()
    center.delegate = shared
    let snooze = UNNotificationAction(identifier: "snooze", title: "Schlummern 10 Min", options: [])
    let snoozeH = UNNotificationAction(identifier: "snooze1h", title: "1 Std", options: [])
    let done = UNNotificationAction(identifier: "done", title: "Erledigt", options: [])
    center.setNotificationCategories([
      UNNotificationCategory(identifier: "junels.reminder", actions: [done, snooze, snoozeH], intentIdentifiers: [], options: [])
    ])
  }

  private static func record(_ ident: String, _ action: String, _ at: Double) {
    guard let id = Int(ident.replacingOccurrences(of: "junels-", with: "")) else { return }
    let d = UserDefaults.standard
    var ev = d.array(forKey: "junels.notifyEvents") ?? []
    ev.append(["id": id, "action": action, "at": at])
    d.set(ev, forKey: "junels.notifyEvents")
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    if #available(macOS 11.0, *) { completionHandler([.banner, .list, .sound]) } else { completionHandler([.alert, .sound]) }
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                              withCompletionHandler completionHandler: @escaping () -> Void) {
    let req = response.notification.request
    switch response.actionIdentifier {
    case "snooze", "snooze1h":
      let mins: Double = response.actionIdentifier == "snooze1h" ? 60 : 10
      let content = (req.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
      content.attachments = []
      center.add(UNNotificationRequest(identifier: req.identifier, content: content,
                                       trigger: UNTimeIntervalNotificationTrigger(timeInterval: mins * 60, repeats: false)))
      JunelsNotifyDelegate.record(req.identifier, "snooze", (Date().timeIntervalSince1970 + mins * 60) * 1000)
    case "done":
      center.removeDeliveredNotifications(withIdentifiers: [req.identifier])
      JunelsNotifyDelegate.record(req.identifier, "done", Date().timeIntervalSince1970 * 1000)
    default:
      NSApp.activate(ignoringOtherApps: true)
      // Absprung ins Thema (Chat, Beobachtung, Prozess)
      if let target = req.content.userInfo["target"] as? String,
         let enc = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
        JunelsDevice.link("junels://open/\(enc)")
      }
    }
    completionHandler()
  }
}
