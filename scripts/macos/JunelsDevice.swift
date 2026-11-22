
// Kanal "junels/device" (Mac): E-Mail, WhatsApp, FaceTime-Anruf, Kalender (EventKit),
// Kontakte, freigegebene Ordner (Lesezeichen), Dateien suchen/umbenennen/verschieben,
// Dock-Menü und Dateien, die aufs Dock-Symbol gezogen werden.
enum JunelsDevice {
  static var channel: FlutterMethodChannel?
  static var quickActions: [(String, String)] = [("conversation", "Gespräch starten"), ("newchat", "Neuer Chat")]
  static var pendingOpen: [String] = []
  static var folders: [String: URL] = [:]   // Lesezeichen-ID → freigegebener Ordner
  static let events = EKEventStore()

  static func register(_ controller: FlutterViewController) {
    let ch = FlutterMethodChannel(name: "junels/device", binaryMessenger: controller.engine.binaryMessenger)
    channel = ch
    startNetworkMonitor()
    ch.setMethodCallHandler { call, result in
      let a = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "networkStatus":
        result(networkOnline)
      // ---- Apps steuern (nur Apps aus der Freigabeliste; die Prüfung macht die App vorher)
      case "listApps":
        DispatchQueue.global(qos: .userInitiated).async {
          var out: [[String: String]] = []
          var seen = Set<String>()
          func add(_ url: URL) {
            guard let id = Bundle(url: url)?.bundleIdentifier, !seen.contains(id), id != Bundle.main.bundleIdentifier else { return }
            seen.insert(id)
            out.append(["name": url.deletingPathExtension().lastPathComponent, "id": id])
          }
          // In der Sandbox ist NSHomeDirectory() der Container – den echten Benutzerordner nehmen
          let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
          for dir in ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities", home + "/Applications"] {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for name in items {
              let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
              if name.hasSuffix(".app") { add(url); continue }
              // Unterordner wie /Applications/Adobe … eine Ebene tiefer
              var isDir: ObjCBool = false
              if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                for sub in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []) where sub.hasSuffix(".app") {
                  add(url.appendingPathComponent(sub))
                }
              }
            }
          }
          // Bekannte Apps über die Startdienste finden, egal wo sie liegen (z. B. Spotify)
          for id in ["com.spotify.client", "com.apple.Music", "com.apple.podcasts", "com.apple.TV", "com.apple.Safari",
                     "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "com.tinyspeck.slackmacgap",
                     "com.microsoft.teams2", "us.zoom.xos", "com.hnc.Discord", "notion.id", "com.microsoft.VSCode",
                     "com.microsoft.Word", "com.microsoft.Excel", "com.microsoft.Powerpoint", "com.microsoft.Outlook",
                     "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop"] where !seen.contains(id) {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { add(url) }
          }
          out.sort { ($0["name"] ?? "").lowercased() < ($1["name"] ?? "").lowercased() }
          DispatchQueue.main.async { result(out) }
        }
      case "launchApp":
        guard let id = a["id"] as? String, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
          result(FlutterError(code: "app", message: "App nicht installiert", details: nil)); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, err in
          DispatchQueue.main.async {
            if let err = err { result(FlutterError(code: "app", message: err.localizedDescription, details: nil)) } else { result(true) }
          }
        }
      case "mediaKey":
        // Musik-Apps per AppleScript (nur die im Entitlement erlaubten: Spotify, Musik, Podcasts, TV)
        let id = a["id"] as? String ?? "com.spotify.client"
        let verb: String
        switch a["key"] as? String ?? "playpause" {
        case "play": verb = "play"
        case "pause": verb = "pause"
        case "next": verb = "next track"
        case "previous": verb = "previous track"
        default: verb = "playpause"
        }
        let safeId = id.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        DispatchQueue.global(qos: .userInitiated).async {
          var err: NSDictionary?
          NSAppleScript(source: "tell application id \"\(safeId)\" to \(verb)")?.executeAndReturnError(&err)
          DispatchQueue.main.async {
            if let err = err {
              result(FlutterError(code: "app", message: (err[NSAppleScript.errorMessage] as? String) ?? "Steuern nicht erlaubt (Systemeinstellungen → Datenschutz → Automation)", details: nil))
            } else { result(true) }
          }
        }
      case "playSearch":
        // Spotify: Link (spotify:playlist:…) per AppleScript abspielen; ohne Link nur die Suche öffnen
        let id = a["id"] as? String ?? "com.spotify.client"
        let safeId = id.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard let uri = a["uri"] as? String, uri.range(of: "^spotify:[a-z]+:[A-Za-z0-9]+$", options: .regularExpression) != nil else {
          result(FlutterError(code: "app", message: "Kein abspielbarer Link gefunden", details: nil)); return
        }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
        let playIt = {
          DispatchQueue.global(qos: .userInitiated).async {
            var err: NSDictionary?
            NSAppleScript(source: "tell application id \"\(safeId)\" to play track \"\(uri)\"")?.executeAndReturnError(&err)
            DispatchQueue.main.async {
              if let err = err {
                result(FlutterError(code: "app", message: (err[NSAppleScript.errorMessage] as? String) ?? "Steuern nicht erlaubt (Systemeinstellungen → Datenschutz → Automation)", details: nil))
              } else { result(true) }
            }
          }
        }
        if running {
          playIt()
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
          NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { playIt() }
          }
        } else {
          result(FlutterError(code: "app", message: "App nicht installiert", details: nil))
        }
      case "openInApp":
        guard let s = a["url"] as? String, let u = URL(string: s) else { result(false); return }
        if let id = a["id"] as? String, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
          // Läuft die App noch nicht, verliert z. B. Spotify den Link beim Kaltstart: erst starten, kurz warten, dann öffnen
          let running = !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty
          let openLink = {
            NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
              DispatchQueue.main.async {
                if let err = err { result(FlutterError(code: "app", message: err.localizedDescription, details: nil)) } else { result(true) }
              }
            }
          }
          if running {
            openLink()
          } else {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
              DispatchQueue.main.asyncAfter(deadline: .now() + 4) { openLink() }
            }
          }
        } else {
          result(NSWorkspace.shared.open(u))
        }
      // Tresor: Geheimnisse im macOS-Schlüsselbund (nicht in den App-Dateien)
      case "vaultSet":
        let key = a["key"] as? String ?? ""
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "io.junels.vault",
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        if let v = a["value"] as? String {
          var add = base
          add[kSecValueData as String] = Data(v.utf8)
          add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
          let st = SecItemAdd(add as CFDictionary, nil)
          if st != errSecSuccess {
            result(FlutterError(code: "vault", message: "Schlüsselbund: Fehler \(st)", details: nil))
            return
          }
        }
        result(true)
      case "vaultGet":
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "io.junels.vault",
                                kSecAttrAccount as String: a["key"] as? String ?? "",
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
          result(String(data: d, encoding: .utf8))
        } else {
          result(nil)
        }
      case "vaultKeys":
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: "io.junels.vault",
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] {
          result(items.compactMap { $0[kSecAttrAccount as String] as? String })
        } else {
          result([String]())
        }
      case "takeLaunch":
        let files = pendingOpen
        pendingOpen = []
        let text = pendingText
        pendingText = nil
        var shared: Any = NSNull()
        if !files.isEmpty || text != nil {
          shared = ["text": text?.0 ?? "", "send": text?.1 ?? false,
                    "files": files.map { ["path": $0, "name": URL(fileURLWithPath: $0).lastPathComponent] }] as [String: Any]
        }
        let action = pendingAction
        pendingAction = nil
        let link = pendingLink
        pendingLink = nil
        result(["action": action ?? NSNull(), "shared": shared, "link": link ?? NSNull()] as [String: Any])
      case "composeEmail":
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = a["to"] as? String ?? ""
        c.queryItems = [URLQueryItem(name: "subject", value: a["subject"] as? String ?? ""),
                        URLQueryItem(name: "body", value: a["body"] as? String ?? "")]
        result(c.url.map { NSWorkspace.shared.open($0) } ?? false)
      case "whatsapp":
        let phone = (a["phone"] as? String ?? "").filter { $0.isNumber }
        var c = URLComponents(string: "whatsapp://send")!
        c.queryItems = [URLQueryItem(name: "phone", value: phone), URLQueryItem(name: "text", value: a["text"] as? String ?? "")]
        if let u = c.url, NSWorkspace.shared.urlForApplication(toOpen: u) != nil {
          result(NSWorkspace.shared.open(u))
        } else {
          var w = URLComponents(string: "https://wa.me/\(phone)")!
          w.queryItems = [URLQueryItem(name: "text", value: a["text"] as? String ?? "")]
          result(w.url.map { NSWorkspace.shared.open($0) } ?? false)
        }
      case "dial":
        let n = (a["number"] as? String ?? "").filter { $0.isNumber || $0 == "+" }
        result(URL(string: "tel:\(n)").map { NSWorkspace.shared.open($0) } ?? false)
      case "calendarInsert":
        // .ics erzeugen und öffnen → Kalender fragt, in welchen Kalender
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyyMMdd"
        let begin = Date(timeIntervalSince1970: ((a["begin"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        let end = Date(timeIntervalSince1970: ((a["end"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        let allDay = a["allDay"] as? Bool ?? false
        func esc(_ s: String) -> String {
          s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;")
        }
        var ics = "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Junels//DE\r\nBEGIN:VEVENT\r\n"
        ics += "UID:\(UUID().uuidString)@junels\r\nDTSTAMP:\(fmt.string(from: Date()))\r\n"
        if allDay {
          ics += "DTSTART;VALUE=DATE:\(dayFmt.string(from: begin))\r\nDTEND;VALUE=DATE:\(dayFmt.string(from: end))\r\n"
        } else {
          ics += "DTSTART:\(fmt.string(from: begin))\r\nDTEND:\(fmt.string(from: end))\r\n"
        }
        ics += "SUMMARY:\(esc(a["title"] as? String ?? "Termin"))\r\n"
        if let l = a["location"] as? String, !l.isEmpty { ics += "LOCATION:\(esc(l))\r\n" }
        if let n = a["notes"] as? String, !n.isEmpty { ics += "DESCRIPTION:\(esc(n))\r\n" }
        ics += "END:VEVENT\r\nEND:VCALENDAR\r\n"
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("Termin-\(Int(Date().timeIntervalSince1970)).ics")
        do {
          try ics.write(to: f, atomically: true, encoding: .utf8)
          result(NSWorkspace.shared.open(f))
        } catch {
          result(FlutterError(code: "calendar", message: error.localizedDescription, details: nil))
        }
      case "calendarList":
        let from = Date(timeIntervalSince1970: ((a["from"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        let to = Date(timeIntervalSince1970: ((a["to"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        let done: (Bool, Error?) -> Void = { ok, err in
          DispatchQueue.main.async {
            guard ok else {
              result(FlutterError(code: "permission", message: err?.localizedDescription ?? "Kein Zugriff auf den Kalender – in den Systemeinstellungen erlauben", details: nil))
              return
            }
            let pred = events.predicateForEvents(withStart: from, end: to, calendars: nil)
            let list = events.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(100).map { e -> [String: Any] in
              ["title": e.title ?? "", "begin": Int(e.startDate.timeIntervalSince1970 * 1000),
               "end": Int(e.endDate.timeIntervalSince1970 * 1000), "allDay": e.isAllDay,
               "location": e.location ?? "", "calendar": e.calendar?.title ?? "",
               "notes": (e.notes ?? "") + ((e.attendees ?? []).map { "\nTeilnehmer: " + $0.url.absoluteString.replacingOccurrences(of: "mailto:", with: "") }.joined())]
            }
            result(Array(list))
          }
        }
        if #available(macOS 14.0, *) {
          events.requestFullAccessToEvents(completion: done)
        } else {
          events.requestAccess(to: .event, completion: done)
        }
      case "contacts":
        let q = a["query"] as? String ?? ""
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { ok, err in
          guard ok else {
            DispatchQueue.main.async {
              result(FlutterError(code: "permission", message: err?.localizedDescription ?? "Kein Zugriff auf Kontakte – in den Systemeinstellungen erlauben", details: nil))
            }
            return
          }
          let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                      CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
          let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: q), keysToFetch: keys)) ?? []
          let list = found.prefix(10).map { c -> [String: Any] in
            let name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return ["name": name.isEmpty ? c.organizationName : name,
                    "phones": c.phoneNumbers.map { $0.value.stringValue },
                    "emails": c.emailAddresses.map { $0.value as String }]
          }
          DispatchQueue.main.async { result(Array(list)) }
        }
      case "pickFolder":
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Freigeben"
        panel.message = a["message"] as? String ?? "Ordner für Junels freigeben"
        guard panel.runModal() == .OK, let url = panel.url else { return result(NSNull()) }
        do {
          let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          let id = data.base64EncodedString()
          _ = url.startAccessingSecurityScopedResource()
          folders[id] = url
          result(["id": id, "name": url.lastPathComponent, "path": url.path])
        } catch {
          result(FlutterError(code: "folder", message: error.localizedDescription, details: nil))
        }
      case "grantFolders":
        // gespeicherte Freigaben beim Start wieder öffnen
        var ok: [[String: String]] = []
        for id in a["ids"] as? [String] ?? [] {
          guard folders[id] == nil, let data = Data(base64Encoded: id) else {
            if let u = folders[id] { ok.append(["id": id, "path": u.path]) }
            continue
          }
          var stale = false
          if let u = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) {
            _ = u.startAccessingSecurityScopedResource()
            folders[id] = u
            ok.append(["id": id, "path": u.path])
          }
        }
        result(ok)
      case "scanFolder":
        guard let root = folders[a["id"] as? String ?? ""] else { return result(FlutterError(code: "folder", message: "Ordner nicht freigegeben", details: nil)) }
        let since = Date(timeIntervalSince1970: ((a["since"] as? NSNumber)?.doubleValue ?? 0) / 1000)
        DispatchQueue.global(qos: .utility).async {
          var out: [[String: Any]] = []
          let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
          if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let u as URL in en {
              if out.count >= 30 { break }
              if en.level > 3 { en.skipDescendants(); continue }
              let ext = u.pathExtension.lowercased()
              guard ["pdf", "txt", "md"].contains(ext) else { continue }
              let v = try? u.resourceValues(forKeys: Set(keys))
              guard v?.isRegularFile == true, let m = v?.contentModificationDate, m > since else { continue }
              out.append(["path": u.path, "name": u.lastPathComponent, "modified": Int(m.timeIntervalSince1970 * 1000)])
            }
          }
          DispatchQueue.main.async { result(out) }
        }
      case "fileSearch":
        let q = (a["query"] as? String ?? "").lowercased()
        let words = q.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let ext = (a["ext"] as? String ?? "").lowercased().replacingOccurrences(of: ".", with: "")
        DispatchQueue.global(qos: .userInitiated).async {
          var out: [[String: Any]] = []
          let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
          for root in folders.values {
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var seen = 0
            for case let u as URL in en {
              seen += 1
              if seen > 20000 || out.count >= 40 { break }
              let name = u.lastPathComponent.lowercased()
              if !ext.isEmpty && u.pathExtension.lowercased() != ext { continue }
              if !words.allSatisfy({ name.contains($0) }) { continue }
              let v = try? u.resourceValues(forKeys: Set(keys))
              out.append(["path": u.path, "name": u.lastPathComponent, "dir": v?.isDirectory ?? false,
                          "size": v?.fileSize ?? 0, "modified": Int((v?.contentModificationDate ?? Date()).timeIntervalSince1970 * 1000)])
            }
          }
          DispatchQueue.main.async { result(out) }
        }
      case "fileRename", "fileMove", "fileMkdir":
        let src = URL(fileURLWithPath: a["path"] as? String ?? "")
        func inside(_ u: URL) -> Bool {
          let p = u.standardizedFileURL.path
          return folders.values.contains { p == $0.standardizedFileURL.path || p.hasPrefix($0.standardizedFileURL.path + "/") }
        }
        do {
          switch call.method {
          case "fileRename":
            let name = (a["name"] as? String ?? "").replacingOccurrences(of: "/", with: "-")
            let dst = src.deletingLastPathComponent().appendingPathComponent(name)
            guard inside(src), inside(dst), !name.isEmpty else { throw NSError(domain: "junels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nur in freigegebenen Ordnern erlaubt"]) }
            if FileManager.default.fileExists(atPath: dst.path) { throw NSError(domain: "junels", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(name) gibt es dort schon"]) }
            try FileManager.default.moveItem(at: src, to: dst)
            result(dst.path)
          case "fileMove":
            let dir = URL(fileURLWithPath: a["folder"] as? String ?? "")
            let dst = dir.appendingPathComponent(src.lastPathComponent)
            guard inside(src), inside(dir) else { throw NSError(domain: "junels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nur in freigegebenen Ordnern erlaubt"]) }
            if FileManager.default.fileExists(atPath: dst.path) { throw NSError(domain: "junels", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(src.lastPathComponent) gibt es im Zielordner schon"]) }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: src, to: dst)
            result(dst.path)
          default:
            guard inside(src) else { throw NSError(domain: "junels", code: 1, userInfo: [NSLocalizedDescriptionKey: "Nur in freigegebenen Ordnern erlaubt"]) }
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            result(src.path)
          }
        } catch {
          result(FlutterError(code: "file", message: error.localizedDescription, details: nil))
        }
      case "setQuickActions":
        let items = a["items"] as? [[String: String]] ?? []
        quickActions = items.map { ($0["id"] ?? "", $0["label"] ?? "") }
        result(true)
      case "pinQuickAction":
        result(false)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // Dock-Menü (Rechtsklick aufs Dock-Symbol)
  // Netzwerkstatus des Systems (online/offline) – Junels sendet dafür selbst nichts
  static var networkOnline = true
  static var netMonitor: NWPathMonitor?
  static func startNetworkMonitor() {
    guard netMonitor == nil else { return }
    let m = NWPathMonitor()
    m.pathUpdateHandler = { path in
      let online = path.status == .satisfied
      DispatchQueue.main.async {
        if online != networkOnline {
          networkOnline = online
          channel?.invokeMethod("network", arguments: ["online": online])
        }
      }
    }
    m.start(queue: DispatchQueue(label: "junels.net"))
    netMonitor = m
  }

  static func dockMenu() -> NSMenu {
    let menu = NSMenu()
    for (id, label) in quickActions {
      let item = NSMenuItem(title: label, action: #selector(DockTarget.run(_:)), keyEquivalent: "")
      item.target = DockTarget.shared
      item.representedObject = id
      menu.addItem(item)
    }
    return menu
  }

  static func launch(_ id: String) {
    NSApp.activate(ignoringOtherApps: true)
    if let ch = channel { ch.invokeMethod("launchAction", arguments: ["id": id]) } else { pendingAction = id }
  }

  static var pendingLink: String?

  /// junels://sso/… usw. an die App (nicht in den Chat).
  static func link(_ url: String) {
    NSApp.activate(ignoringOtherApps: true)
    if let ch = channel { ch.invokeMethod("link", arguments: ["url": url]) } else { pendingLink = url }
  }

  static var pendingText: (String, Bool)?
  static var pendingAction: String?

  /// Text aus dem Dienste-Menü oder einem junels://-Link an den Agenten geben.
  static func shareText(_ text: String, send: Bool = false) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    NSApp.activate(ignoringOtherApps: true)
    if let ch = channel {
      ch.invokeMethod("shared", arguments: ["text": t, "send": send, "files": [Any]()])
    } else {
      pendingText = (t, send)
    }
  }

  /// Dateien, die aufs Dock-Symbol gezogen oder mit „Öffnen mit“ an Junels gegeben wurden.
  static func open(_ paths: [String]) {
    guard !paths.isEmpty else { return }
    NSApp.activate(ignoringOtherApps: true)
    if let ch = channel {
      ch.invokeMethod("shared", arguments: ["text": "", "files": paths.map { ["path": $0, "name": URL(fileURLWithPath: $0).lastPathComponent] }])
    } else {
      pendingOpen.append(contentsOf: paths)
    }
  }
}

final class DockTarget: NSObject {
  static let shared = DockTarget()
  @objc func run(_ sender: NSMenuItem) {
    if let id = sender.representedObject as? String { JunelsDevice.launch(id) }
  }
  @objc func openDocuments(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard let list = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D_2D2D)) else { return }  // '----'
    var paths: [String] = []
    if list.numberOfItems == 0 {
      if let u = list.fileURLValue { paths.append(u.path) }
    } else {
      for i in 1...list.numberOfItems {
        if let u = list.atIndex(i)?.fileURLValue { paths.append(u.path) }
      }
    }
    JunelsDevice.open(paths)
  }
}


/// Dienste-Menü („An Junels senden“) und Links junels://frage?text=… (z. B. aus der Kurzbefehle-App).
final class JunelsServices: NSObject {
  static let shared = JunelsServices()

  @objc func sendToJunels(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
    var text = pboard.string(forType: .string) ?? ""
    if text.isEmpty, let u = pboard.string(forType: .URL) { text = u }
    if text.isEmpty, let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
      let files = urls.filter { $0.isFileURL }.map { $0.path }
      if !files.isEmpty {
        JunelsDevice.open(files)
        return
      }
      text = urls.map { $0.absoluteString }.joined(separator: "\n")
    }
    JunelsDevice.shareText(text)
  }

  @objc func handleURL(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard let s = event.paramDescriptor(forKeyword: AEKeyword(0x2D2D_2D2D))?.stringValue,
          let u = URLComponents(string: s) else { return }
    let q = u.queryItems?.first(where: { ["text", "q", "frage"].contains($0.name) })?.value ?? ""
    switch (u.host ?? "").lowercased() {
    case "sso":
      JunelsDevice.link(s)
    case "neu", "newchat", "chat":
      JunelsDevice.launch("newchat")
      if !q.isEmpty { JunelsDevice.shareText(q) }
    case "sprechen", "gespraech", "gespräch", "voice":
      JunelsDevice.launch("conversation")
    case "einfuegen", "text":
      JunelsDevice.shareText(q)
    default:  // frage, ask
      if q.isEmpty { JunelsDevice.launch("newchat") } else { JunelsDevice.shareText(q, send: true) }
    }
  }
}
