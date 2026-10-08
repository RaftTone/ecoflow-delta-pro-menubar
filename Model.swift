// Модель даних EcoFlow: конфіг із Keychain, знімок стану, підписаний API (читання й запис), стан картки.
//
// 🔑 «Вхід» = лише ЗОВНІШНІЙ: мережа (inv.inputWatts) + DC-вхід (mppt.inWatts: сонця в власника нема, сюди в екстрених випадках йде Tesla). Застосунок EcoFlow показує
// pd.wattsInSum, куди входить і перелив з другої батареї в основну (315 Вт при вимкненому світлі); тут,
// як просив власник, без мережі й сонця вхід = 0.
//
// 🔴 EcoFlow на будь-яку команду відповідає code=0 «Success», це лише «прийнято до пересилання».
// Єдина чесна перевірка запису: зчитати значення назад (так само, як у ecoflow_client.py).

import AppKit
import CryptoKit

// MARK: - Конфіг із Keychain

struct EFConfig {
    let accessKey: String
    let secretKey: String
    let sn: String
    let host: String

    static func load() -> EFConfig? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "ua.rafttone.ecoflowbar", "-a", "ecoflow", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let obj = try? JSONSerialization.jsonObject(with: out.fileHandleForReading.readDataToEndOfFile()) as? [String: Any],
              let ak = obj["access_key"] as? String, let sk = obj["secret_key"] as? String,
              let sn = obj["sn"] as? String else { return nil }
        let region = (obj["region"] as? String) ?? "eu"
        return EFConfig(accessKey: ak, secretKey: sk, sn: sn,
                        host: region == "us" ? "https://api-a.ecoflow.com" : "https://api-e.ecoflow.com")
    }
}

// MARK: - Знімок стану станції

struct Snapshot {
    var soc: Double?                 // ems.f32LcdShowSoc: те саме число, що на екрані станції
    var socMaster: Double?
    var socSlave: Double?
    var acInW = 0.0                  // inv.inputWatts: мережа
    var dcInW = 0.0                  // mppt.inWatts: DC-вхід (сонця нема, власник в екстрених випадках подає сюди Tesla)
    var acInV = 0.0
    var acOutW = 0.0                 // inv.outputWatts
    var dc12W = 0.0                  // mppt.dcdc12vWatts («12V DC»)
    var carW = 0.0                   // pd.carWatts («12V 30A»)
    var usb1 = 0.0, usb2 = 0.0       // USB-A
    var qc1 = 0.0, qc2 = 0.0         // FAST
    var c1 = 0.0, c2 = 0.0           // Type-C
    var totalOutW = 0.0              // pd.wattsOutSum, як «Output» в застосунку
    var xboost = false
    var maxSoc: Int?                 // ems.maxChargeSoc: «Заряджати до»
    var minSoc: Int?                 // ems.minDsgSoc: «Розряджати до»
    var acChargeW: Int?              // inv.cfgSlowChgWatts: швидкість зарядки від мережі
    var chgRemainMin: Double?
    var dsgRemainMin: Double?
    var tempC: Double?
    var fetched = Date()

    var externalInW: Double { acInW + dcInW }
    var grid: Bool { acInV > 50 }
    var charging: Bool { externalInW > 5 }
}

// MARK: - API

enum EFError: LocalizedError {
    case msg(String)
    var errorDescription: String? { if case .msg(let m) = self { return m }; return nil }
}

enum EcoFlowAPI {
    static func hmacHex(key: String, message: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func flatten(_ obj: Any, prefix: String = "", into out: inout [String: Any]) {
        if let d = obj as? [String: Any] {
            for (k, v) in d { flatten(v, prefix: prefix.isEmpty ? k : prefix + "." + k, into: &out) }
        } else {
            out[prefix] = obj
        }
    }

    static func number(_ v: Any?) -> Double? {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    /// Підпис: усі поля (параметри/тіло розгорнуті через крапку) за ASCII, далі accessKey, nonce, timestamp.
    static func signedHeaders(_ cfg: EFConfig, fields: [String: Any]) -> [String: String] {
        let nonce = String(Int.random(in: 100000...999999))
        let ts = String(Int(Date().timeIntervalSince1970 * 1000))
        var flat: [String: Any] = [:]
        flatten(fields, into: &flat)
        let q = flat.keys.sorted().map { "\($0)=\(flat[$0]!)" }.joined(separator: "&")
        let head = "accessKey=\(cfg.accessKey)&nonce=\(nonce)&timestamp=\(ts)"
        let sign = hmacHex(key: cfg.secretKey, message: (q.isEmpty ? "" : q + "&") + head)
        return ["accessKey": cfg.accessKey, "nonce": nonce, "timestamp": ts, "sign": sign]
    }

    static func decode(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw EFError.msg(L.t("EcoFlow returned non-JSON", "EcoFlow віддав не JSON")) }
        guard "\(root["code"] ?? "")" == "0" else { throw EFError.msg("EcoFlow: \(root["message"] ?? L.t("error", "помилка"))") }
        return root
    }

    static func fetch(_ cfg: EFConfig) async throws -> Snapshot {
        var comps = URLComponents(string: cfg.host + "/iot-open/sign/device/quota/all")!
        comps.queryItems = [URLQueryItem(name: "sn", value: cfg.sn)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        for (k, v) in signedHeaders(cfg, fields: ["sn": cfg.sn]) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        let root = try decode(data)
        var f: [String: Any] = [:]
        flatten(root["data"] ?? [:], into: &f)
        func n(_ k: String) -> Double { number(f[k]) ?? 0 }
        func i(_ k: String) -> Int? { number(f[k]).map { Int($0.rounded()) } }
        var s = Snapshot()
        s.soc = number(f["ems.f32LcdShowSoc"])
        s.socMaster = number(f["bmsMaster.soc"])
        s.socSlave = number(f["bmsSlave1.soc"])
        s.acInW = n("inv.inputWatts"); s.dcInW = n("mppt.inWatts")
        s.acInV = n("inv.acInVol") / 1000
        s.acOutW = n("inv.outputWatts"); s.dc12W = n("mppt.dcdc12vWatts"); s.carW = n("pd.carWatts")
        s.usb1 = n("pd.usb1Watts"); s.usb2 = n("pd.usb2Watts")
        s.qc1 = n("pd.qcUsb1Watts"); s.qc2 = n("pd.qcUsb2Watts")
        s.c1 = n("pd.typec1Watts"); s.c2 = n("pd.typec2Watts")
        s.totalOutW = number(f["pd.wattsOutSum"]) ?? s.acOutW
        s.xboost = (i("inv.cfgAcXboost") ?? 0) == 1
        s.maxSoc = i("ems.maxChargeSoc"); s.minSoc = i("ems.minDsgSoc"); s.acChargeW = i("inv.cfgSlowChgWatts")
        s.chgRemainMin = number(f["ems.chgRemainTime"]); s.dsgRemainMin = number(f["ems.dsgRemainTime"])
        s.tempC = number(f["bmsMaster.temp"])
        if s.soc == nil { throw EFError.msg(L.t("no charge level in the response", "у відповіді нема заряду")) }
        return s
    }

    /// Запис параметра. Підписується ТІЛО (розгорнуте через крапку), формат legacy-набору DELTA Pro.
    static func put(_ cfg: EFConfig, body: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: cfg.host + "/iot-open/sign/device/quota")!, timeoutInterval: 20)
        req.httpMethod = "PUT"
        for (k, v) in signedHeaders(cfg, fields: body) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        _ = try decode(data)
    }
}

// MARK: - Стан картки

@MainActor
final class Model: ObservableObject {
    @Published var snap: Snapshot?
    @Published var error: String?
    @Published var editMax = 100
    @Published var editMin = 10
    @Published var editSpeed = 1550
    @Published var busy = false
    @Published var result: [String] = []

    static let maxRange = 50...100, minRange = 0...30, speedRange = 200...2900

    var isStale: Bool { snap.map { Date().timeIntervalSince($0.fetched) > 300 } ?? true }

    var dirty: Bool {
        guard let s = snap else { return false }
        return editMax != s.maxSoc || editMin != s.minSoc || editSpeed != s.acChargeW
    }

    /// Підтягнути поля керування зі станції, але не затирати те, що людина зараз правила.
    func syncEdits(force: Bool = false) {
        guard let s = snap, force || !dirty, !busy else { return }
        if let v = s.maxSoc { editMax = v }
        if let v = s.minSoc { editMin = v }
        if let v = s.acChargeW { editSpeed = v }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard let cfg = EFConfig.load() else {
            error = L.t("No EcoFlow keys in Keychain", "Немає ключів EcoFlow у Keychain")
            return false
        }
        do {
            let wasClean = !dirty
            snap = try await EcoFlowAPI.fetch(cfg)
            error = nil
            if wasClean { syncEdits() }
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Записати лише змінене й ПЕРЕВІРИТИ зчитуванням: «Success» від EcoFlow нічого не доводить.
    func apply() async {
        guard let cfg = EFConfig.load(), let s = snap, !busy else { return }
        busy = true
        result = []
        defer { busy = false }

        struct Job { let name: String; let params: [String: Any]; let target: Int; let read: (Snapshot) -> Int? }
        var jobs: [Job] = []
        let mx = min(Model.maxRange.upperBound, max(Model.maxRange.lowerBound, editMax))
        let mn = min(Model.minRange.upperBound, max(Model.minRange.lowerBound, editMin))
        let sp = min(Model.speedRange.upperBound, max(Model.speedRange.lowerBound, editSpeed))
        if mx != s.maxSoc { jobs.append(Job(name: L.t("Charge to \(mx)%", "Заряджати до \(mx)%"), params: ["cmdSet": 32, "id": 49, "maxChgSoc": mx], target: mx, read: { $0.maxSoc })) }
        if mn != s.minSoc { jobs.append(Job(name: L.t("Discharge to \(mn)%", "Розряджати до \(mn)%"), params: ["cmdSet": 32, "id": 51, "discLvl": mn], target: mn, read: { $0.minSoc })) }
        if sp != s.acChargeW { jobs.append(Job(name: L.t("Charging speed \(sp) W", "Швидкість зарядки \(sp) Вт"), params: ["cmdSet": 32, "id": 69, "slowChgPower": sp], target: sp, read: { $0.acChargeW })) }

        for job in jobs {
            do {
                try await EcoFlowAPI.put(cfg, body: ["sn": cfg.sn, "operateType": "TCP", "params": job.params])
            } catch {
                result.append("⚠️ \(job.name): \(error.localizedDescription)")
                continue
            }
            var confirmed = false
            for _ in 0..<10 {                              // станція застосовує не миттєво
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let fresh = try? await EcoFlowAPI.fetch(cfg) {
                    snap = fresh
                    if job.read(fresh) == job.target { confirmed = true; break }
                }
            }
            result.append(confirmed ? L.t("✓ \(job.name): confirmed by the station", "✓ \(job.name): станція підтвердила")
                                    : L.t("⚠️ \(job.name): not confirmed within 20 s", "⚠️ \(job.name): станція не підтвердила за 20 с"))
        }
        syncEdits(force: true)
    }
}
