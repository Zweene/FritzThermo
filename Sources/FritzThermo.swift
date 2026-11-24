// FritzThermo – zeigt FRITZ!DECT 301 / 440 (und andere Temperatur-Geräte)
// in der macOS-Menüleiste an. Benötigt macOS 13 (Ventura) oder neuer.

import AppKit
import SwiftUI
import Foundation
import CommonCrypto
import CryptoKit
import Security
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - App

@main
struct FritzThermoApp: App {
    @StateObject private var model = ThermoModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            if let icon = model.menuBarIcon {
                HStack(spacing: 4) {
                    Image(nsImage: icon)
                    Text(model.menuBarValue)
                }
            } else {
                Text("🌡 " + model.menuBarValue)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Datenmodell

enum Target: Hashable {
    case none, off, on, value(Double)
}

struct FritzDevice: Identifiable, Hashable {
    let id: String          // AIN
    let name: String
    let product: String
    let present: Bool
    let isThermostat: Bool
    let temperature: Double?
    var target: Target
    let comfort: Double?
    let eco: Double?
    let humidity: Int?
    let battery: Int?
    let batteryLow: Bool
    let windowOpen: Bool
    let boost: Bool
}

enum Fmt {
    static func temp(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(1))) + "°"
    }
}

// MARK: - ViewModel

@MainActor
final class ThermoModel: ObservableObject {
    @Published var devices: [FritzDevice] = []
    @Published var lastUpdate: Date?
    @Published var errorMessage: String?
    @Published var isLoading = false

    @Published var host: String
    @Published var username: String
    @Published var interval: Double
    @Published var pinnedAIN: String
    @Published var showHumidityInMenuBar: Bool
    @Published var configured: Bool
    @Published var showSettings = false
    @Published var menuBarIcon: NSImage?

    private(set) var password: String
    private let defaults = UserDefaults.standard
    private let client = FritzClient()
    private var pollTask: Task<Void, Never>?

    init() {
        host = defaults.string(forKey: "host") ?? "fritz.box"
        username = defaults.string(forKey: "username") ?? ""
        let iv = defaults.double(forKey: "interval")
        interval = iv > 0 ? iv : 60
        pinnedAIN = defaults.string(forKey: "pinnedAIN") ?? ""
        showHumidityInMenuBar = defaults.bool(forKey: "showHumidity")
        configured = defaults.bool(forKey: "configured")
        password = Keychain.load() ?? ""
        menuBarIcon = Self.loadIcon()
        if configured { restartPolling() }
    }

    // MARK: Eigenes Menüleisten-Symbol

    private static var iconFile: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FritzThermo", isDirectory: true)
        return dir.appendingPathComponent("menubar-icon.dat")
    }

    private static func loadIcon() -> NSImage? {
        guard let data = try? Data(contentsOf: iconFile), let img = NSImage(data: data),
              img.size.height > 0 else { return nil }
        let h: CGFloat = 18
        let w = min(40, img.size.width / img.size.height * h)
        let out = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            img.draw(in: rect)
            return true
        }
        out.isTemplate = false
        return out
    }

    func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Bild für die Menüleiste auswählen"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url), NSImage(data: data) != nil else { return }
        let file = Self.iconFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: file)
        menuBarIcon = Self.loadIcon()
    }

    func removeIcon() {
        try? FileManager.default.removeItem(at: Self.iconFile)
        menuBarIcon = nil
    }

    var pinnedDevice: FritzDevice? {
        devices.first { $0.id == pinnedAIN }
            ?? devices.first { $0.isThermostat && $0.temperature != nil }
            ?? devices.first { $0.temperature != nil }
    }

    var menuBarValue: String {
        guard let d = pinnedDevice, let t = d.temperature else {
            return errorMessage == nil ? "…" : "⚠︎"
        }
        var s = Fmt.temp(t)
        if showHumidityInMenuBar {
            let h = d.humidity ?? devices.first(where: { $0.humidity != nil })?.humidity
            if let h { s += "  💧\(h) %" }
        }
        return s
    }

    func pin(_ device: FritzDevice) {
        pinnedAIN = device.id
        defaults.set(device.id, forKey: "pinnedAIN")
    }

    func adjust(_ device: FritzDevice, by delta: Double) {
        let current: Double
        switch device.target {
        case .value(let v): current = v
        case .off: current = delta > 0 ? 7.5 : 8
        case .on: current = delta < 0 ? 28.5 : 28
        case .none: current = device.temperature.map { ($0 * 2).rounded() / 2 } ?? 20
        }
        let next = current + delta
        if next < 8 { setTarget(device, .off) }
        else if next > 28 { setTarget(device, .on) }
        else { setTarget(device, .value(next)) }
    }

    func setTarget(_ device: FritzDevice, _ target: Target) {
        let param: Int
        switch target {
        case .off: param = 253
        case .on: param = 254
        case .value(let v): param = min(56, max(16, Int((v * 2).rounded())))
        case .none: return
        }
        // sofort in der Oberfläche anzeigen
        if let i = devices.firstIndex(where: { $0.id == device.id }) {
            devices[i].target = target
        }
        let (h, u, p) = (host, username, password)
        Task {
            do {
                try await client.setTarget(host: h, username: u, password: p, ain: device.id, param: param)
                errorMessage = nil
            } catch {
                errorMessage = "Temperatur setzen: \(error.localizedDescription)"
            }
        }
    }

    func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let secs = self.interval
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
        }
    }

    func refresh() async {
        guard configured, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            devices = try await client.devices(host: host, username: username, password: password)
            lastUpdate = Date()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func save(host: String, username: String, password: String,
              interval: Double, showHumidity: Bool, launchAtLogin: Bool) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.interval = interval
        self.showHumidityInMenuBar = showHumidity
        defaults.set(self.host, forKey: "host")
        defaults.set(self.username, forKey: "username")
        defaults.set(interval, forKey: "interval")
        defaults.set(showHumidity, forKey: "showHumidity")
        if password != self.password {
            self.password = password
            Keychain.save(password)
        }
        configured = true
        defaults.set(true, forKey: "configured")

        let service = SMAppService.mainApp
        do {
            if launchAtLogin, service.status != .enabled {
                try service.register()
            } else if !launchAtLogin, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            errorMessage = "Autostart: \(error.localizedDescription)"
        }
        restartPolling()
    }
}

// MARK: - FRITZ!Box-Client (AHA-HTTP-Interface)

enum FritzError: LocalizedError {
    case badURL, loginFailed, blocked(Int), http(Int), parse

    var errorDescription: String? {
        switch self {
        case .badURL: return "Ungültige Adresse der FRITZ!Box."
        case .loginFailed: return "Anmeldung fehlgeschlagen – Benutzer/Passwort prüfen (Recht „Smart Home“ nötig)."
        case .blocked(let s): return "Anmeldung für \(s) s gesperrt (zu viele Fehlversuche)."
        case .http(let c): return "FRITZ!Box antwortet mit HTTP \(c)."
        case .parse: return "Antwort der FRITZ!Box nicht lesbar."
        }
    }
}

actor FritzClient {
    private var sid: String?
    private var sessionKey = ""
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    func devices(host: String, username: String, password: String) async throws -> [FritzDevice] {
        let data = try await command(host: host, username: username, password: password,
                                     [URLQueryItem(name: "switchcmd", value: "getdevicelistinfos")])
        return try DeviceParser.parse(data)
    }

    /// param: 16…56 = Temperatur × 2, 253 = Aus, 254 = An
    func setTarget(host: String, username: String, password: String, ain: String, param: Int) async throws {
        _ = try await command(host: host, username: username, password: password, [
            URLQueryItem(name: "switchcmd", value: "sethkrtsoll"),
            URLQueryItem(name: "ain", value: ain),
            URLQueryItem(name: "param", value: String(param)),
        ])
    }

    private func command(host: String, username: String, password: String,
                         _ query: [URLQueryItem]) async throws -> Data {
        let key = host + "\u{1}" + username + "\u{1}" + password
        if key != sessionKey { sid = nil; sessionKey = key }

        for attempt in 0..<2 {
            if sid == nil {
                sid = try await login(host: host, username: username, password: password)
            }
            let url = try makeURL(host, "/webservices/homeautoswitch.lua",
                                  query + [URLQueryItem(name: "sid", value: sid)])
            let (data, status) = try await get(url)
            if status == 403 {           // Session abgelaufen → neu anmelden
                sid = nil
                if attempt == 0 { continue }
                throw FritzError.loginFailed
            }
            guard status == 200 else { throw FritzError.http(status) }
            return data
        }
        throw FritzError.loginFailed
    }

    private func makeURL(_ host: String, _ path: String, _ query: [URLQueryItem]) throws -> URL {
        var base = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { throw FritzError.badURL }
        if !base.contains("://") { base = "http://" + base }
        guard var comps = URLComponents(string: base) else { throw FritzError.badURL }
        comps.path = path
        comps.queryItems = query.isEmpty ? nil : query
        guard let url = comps.url else { throw FritzError.badURL }
        return url
    }

    private func get(_ url: URL) async throws -> (Data, Int) {
        let (data, resp) = try await session.data(from: url)
        return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func login(host: String, username: String, password: String) async throws -> String {
        let loginURL = try makeURL(host, "/login_sid.lua", [URLQueryItem(name: "version", value: "2")])
        let (data, _) = try await get(loginURL)
        let info = try LoginInfo(data)
        if info.sid != LoginInfo.invalidSID { return info.sid }

        if info.blockTime > 0 {
            try await Task.sleep(nanoseconds: UInt64(info.blockTime) * 1_000_000_000)
        }
        let user = username.isEmpty ? (info.lastUser ?? "") : username
        let response = Self.challengeResponse(info.challenge, password: password)

        var req = URLRequest(url: loginURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode([("username", user), ("response", response)]).data(using: .utf8)
        let (d2, _) = try await session.data(for: req)
        let result = try LoginInfo(d2)
        guard result.sid != LoginInfo.invalidSID else {
            throw result.blockTime > 0 ? FritzError.blocked(result.blockTime) : FritzError.loginFailed
        }
        return result.sid
    }

    static func formEncode(_ items: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return items.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    /// Challenge-Response nach AVM-Doku: PBKDF2 (FRITZ!OS ≥ 7.24) oder MD5 (älter).
    static func challengeResponse(_ challenge: String, password: String) -> String {
        if challenge.hasPrefix("2$") {
            let p = challenge.split(separator: "$").map(String.init)
            guard p.count == 5, let it1 = Int(p[1]), let it2 = Int(p[3]),
                  let salt1 = Data(hex: p[2]), let salt2 = Data(hex: p[4]) else { return "" }
            let hash1 = pbkdf2(Data(password.utf8), salt: salt1, iterations: it1)
            let hash2 = pbkdf2(hash1, salt: salt2, iterations: it2)
            return p[4] + "$" + hash2.hexString
        } else {
            var bytes: [UInt8] = []
            for u in (challenge + "-" + password).utf16 {
                let c: UInt16 = u > 255 ? 0x2E : u
                bytes.append(UInt8(c & 0xFF))
                bytes.append(UInt8(c >> 8))
            }
            let digest = Insecure.MD5.hash(data: Data(bytes))
            return challenge + "-" + digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    static func pbkdf2(_ password: Data, salt: Data, iterations: Int) -> Data {
        let pw = password.map { CChar(bitPattern: $0) }
        let sl = [UInt8](salt)
        var derived = [UInt8](repeating: 0, count: 32)
        _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw, pw.count,
                                 sl, sl.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                 UInt32(iterations),
                                 &derived, derived.count)
        return Data(derived)
    }
}

struct LoginInfo {
    static let invalidSID = "0000000000000000"
    let sid: String
    let challenge: String
    let blockTime: Int
    let lastUser: String?

    init(_ data: Data) throws {
        let doc = try XMLDocument(data: data)
        func v(_ path: String) -> String? { try? doc.nodes(forXPath: path).first?.stringValue }
        guard let sid = v("//SID") else { throw FritzError.parse }
        self.sid = sid
        challenge = v("//Challenge") ?? ""
        blockTime = Int(v("//BlockTime") ?? "0") ?? 0
        lastUser = v("//User[@last='1']")
    }
}

enum DeviceParser {
    static func parse(_ data: Data) throws -> [FritzDevice] {
        guard let doc = try? XMLDocument(data: data),
              let nodes = try? doc.nodes(forXPath: "/devicelist/device") else { throw FritzError.parse }

        return nodes.compactMap { node -> FritzDevice? in
            guard let el = node as? XMLElement else { return nil }

            func str(_ path: String) -> String? {
                guard let s = (try? el.nodes(forXPath: path))?.first?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return s
            }
            func int(_ path: String) -> Int? { str(path).flatMap { Int($0) } }
            func has(_ path: String) -> Bool { !((try? el.nodes(forXPath: path)) ?? []).isEmpty }

            let isThermostat = has("hkr")
            guard isThermostat || has("temperature") || has("humidity") else { return nil }

            var temp = int("temperature/celsius").map { Double($0) / 10 }
            if temp == nil, let t = int("hkr/tist"), t > 0, t < 253 { temp = Double(t) / 2 }

            var target = Target.none
            if let s = int("hkr/tsoll") {
                switch s {
                case 253: target = .off
                case 254: target = .on
                case 16...56: target = .value(Double(s) / 2)
                default: break
                }
            }

            func halfDegrees(_ path: String) -> Double? {
                guard let v = int(path), (16...56).contains(v) else { return nil }
                return Double(v) / 2
            }

            let ain = el.attribute(forName: "identifier")?.stringValue ?? UUID().uuidString
            return FritzDevice(
                id: ain,
                name: str("name") ?? ain,
                product: el.attribute(forName: "productname")?.stringValue ?? "",
                present: int("present") == 1,
                isThermostat: isThermostat,
                temperature: temp,
                target: target,
                comfort: halfDegrees("hkr/komfort"),
                eco: halfDegrees("hkr/absenk"),
                humidity: int("humidity/rel_humidity"),
                battery: int("battery") ?? int("hkr/battery"),
                batteryLow: (int("batterylow") ?? int("hkr/batterylow")) == 1,
                windowOpen: int("hkr/windowopenactiv") == 1,
                boost: int("hkr/boostactive") == 1
            )
        }
    }
}

// MARK: - Keychain

enum Keychain {
    private static let service = "FritzThermo"
    private static let account = "fritzbox"

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ password: String) {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

// MARK: - Helpers

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var d = Data(capacity: hex.count / 2)
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<n], radix: 16) else { return nil }
            d.append(b)
            i = n
        }
        self = d
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var model: ThermoModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("FRITZ!DECT").font(.headline)
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Jetzt aktualisieren")
                .disabled(!model.configured)
                Button { model.showSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                }
                .help("Einstellungen")
            }
            .buttonStyle(.borderless)

            Divider()

            if model.showSettings || !model.configured {
                SettingsView { model.showSettings = false }
            } else if model.devices.isEmpty {
                Text(model.isLoading ? "Lade Geräte …" : "Keine Thermostate gefunden.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.devices) { d in
                        DeviceRow(device: d, pinned: d.id == model.pinnedDevice?.id) {
                            model.pin(d)
                        }
                        if d.id != model.devices.last?.id { Divider().opacity(0.5) }
                    }
                }
            }

            Divider()

            HStack(alignment: .top) {
                if let e = model.errorMessage {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let d = model.lastUpdate {
                    Text("Aktualisiert \(d.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

struct DeviceRow: View {
    @EnvironmentObject var model: ThermoModel
    let device: FritzDevice
    let pinned: Bool
    let onPin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mainLine
            if device.isThermostat && device.present { controls }
        }
        .opacity(device.present ? 1 : 0.45)
    }

    private var targetText: String {
        switch device.target {
        case .value(let v): return Fmt.temp(v)
        case .off: return "Aus"
        case .on: return "An"
        case .none: return "–"
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Text("Soll").font(.caption).foregroundStyle(.secondary)
            Button { model.adjust(device, by: -0.5) } label: {
                Image(systemName: "minus.circle.fill").font(.title3)
            }
            .disabled(device.target == .off)
            Text(targetText)
                .font(.system(.body, design: .rounded).weight(.medium))
                .monospacedDigit()
                .frame(minWidth: 46)
            Button { model.adjust(device, by: 0.5) } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
            .disabled(device.target == .on)
            Spacer()
            Menu {
                if let c = device.comfort {
                    Button("Komfort (\(Fmt.temp(c)))") { model.setTarget(device, .value(c)) }
                }
                if let e = device.eco {
                    Button("Absenk (\(Fmt.temp(e)))") { model.setTarget(device, .value(e)) }
                }
                Divider()
                Button("Aus (Frostschutz)") { model.setTarget(device, .off) }
                Button("An (volle Leistung)") { model.setTarget(device, .on) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.leading, 32)
    }

    private var mainLine: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isThermostat ? "thermometer.medium" : "humidity")
                .font(.title3)
                .foregroundStyle(device.isThermostat ? .orange : .blue)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(device.name).fontWeight(.medium).lineLimit(1)
                    if pinned {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                }
                Text(detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(device.temperature.map(Fmt.temp) ?? "–")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if let h = device.humidity {
                    Text("💧 \(h) %").font(.caption).monospacedDigit()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onPin)
        .help("Klicken, um diesen Wert in der Menüleiste anzuzeigen")
    }

    private var detailLine: String {
        var parts: [String] = []
        if !device.present { parts.append("nicht erreichbar") }
        if !(device.isThermostat && device.present) {
            switch device.target {
            case .value(let v): parts.append("Soll " + Fmt.temp(v))
            case .off: parts.append("Aus")
            case .on: parts.append("Ein (max.)")
            case .none: break
            }
        }
        if device.windowOpen { parts.append("Fenster offen") }
        if device.boost { parts.append("Boost") }
        if let b = device.battery {
            parts.append((device.batteryLow ? "🪫 " : "🔋 ") + "\(b) %")
        } else if device.batteryLow {
            parts.append("🪫 Batterie schwach")
        }
        if parts.isEmpty { parts.append(device.product) }
        return parts.joined(separator: " · ")
    }
}

/// Ersatz für @State (das Makro-Plugin fehlt in den Command Line Tools)
final class SettingsForm: ObservableObject {
    @Published var host = ""
    @Published var user = ""
    @Published var password = ""
    @Published var interval = 60.0
    @Published var showHumidity = false
    @Published var launchAtLogin = false
}

struct SettingsView: View {
    @EnvironmentObject var model: ThermoModel
    var done: () -> Void

    @StateObject private var form = SettingsForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Einstellungen").font(.subheadline.bold())
            row("Adresse") { TextField("fritz.box", text: $form.host) }
            row("Benutzer") { TextField("z. B. fritz1234", text: $form.user) }
            row("Passwort") { SecureField("", text: $form.password) }
            row("Intervall") {
                Picker("", selection: $form.interval) {
                    Text("30 Sekunden").tag(30.0)
                    Text("1 Minute").tag(60.0)
                    Text("2 Minuten").tag(120.0)
                    Text("5 Minuten").tag(300.0)
                }
                .labelsHidden()
            }
            Toggle("Luftfeuchte in der Menüleiste zeigen", isOn: $form.showHumidity)
            Toggle("Bei Anmeldung automatisch starten", isOn: $form.launchAtLogin)
            HStack {
                Text("Symbol").frame(width: 70, alignment: .leading)
                if let icon = model.menuBarIcon {
                    Image(nsImage: icon)
                } else {
                    Text("🌡")
                }
                Button("Bild wählen …") { model.chooseIcon() }
                if model.menuBarIcon != nil {
                    Button("Standard") { model.removeIcon() }
                }
            }
            Text("Der Benutzer braucht in der FRITZ!Box das Recht „Smart Home“. Leerer Benutzer = zuletzt angemeldeter Benutzer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if model.configured { Button("Abbrechen", action: done) }
                Button("Speichern") {
                    model.save(host: form.host, username: form.user, password: form.password,
                               interval: form.interval, showHumidity: form.showHumidity,
                               launchAtLogin: form.launchAtLogin)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .textFieldStyle(.roundedBorder)
        .onAppear {
            form.host = model.host
            form.user = model.username
            form.password = model.password
            form.interval = model.interval
            form.showHumidity = model.showHumidityInMenuBar
            form.launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(label).frame(width: 70, alignment: .leading)
            content()
        }
    }
}
