
// Kanal "junels/files": PDF-Text lesen (PDFKit), Dateien öffnen, im Finder zeigen, teilen.
enum JunelsFiles {
  static func register(_ controller: FlutterViewController) {
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
      case "notify":
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
          guard granted else { return }
          let content = UNMutableNotificationContent()
          content.title = args["title"] as? String ?? "Junels"
          content.body = args["body"] as? String ?? ""
          content.sound = .default
          var trigger: UNNotificationTrigger? = nil
          if let at = args["at"] as? NSNumber {
            let secs = at.doubleValue / 1000 - Date().timeIntervalSince1970
            if secs > 1 { trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false) }
          }
          center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
        }
        result(true)
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
