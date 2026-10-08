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
    let sn: String?          // необов'язковий: пристрої беремо зі списку акаунта, це лише запасний/типовий
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
              let ak = obj["access_key"] as? String, let sk = obj["secret_key"] as? String else { return nil }
        let sn = obj["sn"] as? String
        let region = (obj["region"] as? String) ?? "eu"
        return EFConfig(accessKey: ak, secretKey: sk, sn: sn,
                        host: region == "us" ? "https://api-a.ecoflow.com" : "https://api-e.ecoflow.com")
    }
}

// MARK: - Пристрій

struct Device: Identifiable, Equatable {
    var id: String { sn }
    let sn: String
    var name: String
    var online: Bool
    var product: String
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
    var supportsControls = false     // лише DELTA Pro (legacy-команди): для інших моделей картка тільки читає
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

    /// Усі пристрої акаунта (назва, чи онлайн). Це дає змогу не прописувати серійники вручну.
    static func devices(_ cfg: EFConfig) async throws -> [Device] {
        var req = URLRequest(url: URL(string: cfg.host + "/iot-open/sign/device/list")!, timeoutInterval: 20)
        for (k, v) in signedHeaders(cfg, fields: [:]) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        let root = try decode(data)
        let arr = (root["data"] as? [[String: Any]]) ?? []
        return arr.compactMap { d in
            guard let sn = d["sn"] as? String else { return nil }
            let product = (d["productName"] as? String) ?? ""
            let name = (d["deviceName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (product.isEmpty ? "EcoFlow" : product)
            return Device(sn: sn, name: name, online: "\(d["online"] ?? 1)" != "0", product: product)
        }
    }

    static func fetch(_ cfg: EFConfig, sn: String) async throws -> Snapshot {
        var comps = URLComponents(string: cfg.host + "/iot-open/sign/device/quota/all")!
        comps.queryItems = [URLQueryItem(name: "sn", value: sn)]
        var req = URLRequest(url: comps.url!, timeoutInterval: 20)
        for (k, v) in signedHeaders(cfg, fields: ["sn": sn]) { req.setValue(v, forHTTPHeaderField: k) }
        let (data, _) = try await URLSession.shared.data(for: req)
        let root = try decode(data)
        var f: [String: Any] = [:]
        flatten(root["data"] ?? [:], into: &f)
        return try parse(f)
    }

    /// Розбір відповіді. DELTA Pro (є `ems.f32LcdShowSoc` і `inv.cfgSlowChgWatts`) читається повністю й дозволяє керування.
    /// Інші моделі: «найкраща спроба» лише на читання за переліком типових назв полів (НЕ перевірено на їхньому залізі).
    static func parse(_ f: [String: Any]) throws -> Snapshot {
        func n(_ k: String) -> Double { number(f[k]) ?? 0 }
        func first(_ keys: [String]) -> Double? { for k in keys { if let v = number(f[k]) { return v } }; return nil }
        func i(_ k: String) -> Int? { number(f[k]).map { Int($0.rounded()) } }
        var s = Snapshot()
        s.supportsControls = f["ems.f32LcdShowSoc"] != nil && f["inv.cfgSlowChgWatts"] != nil
        if s.supportsControls {
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
        } else {
            s.soc = first(["ems.f32LcdShowSoc", "bms_bmsStatus.f32ShowSoc", "bms_emsStatus.f32LcdShowSoc", "bms_bmsStatus.soc",
                           "pd.soc", "bmsMaster.soc", "bms_emsStatus.lcdShowSoc", "ems.lcdShowSoc"])
            s.acInW = first(["inv.inputWatts", "pd.wattsInSum"]) ?? 0
            s.totalOutW = first(["pd.wattsOutSum", "inv.outputWatts"]) ?? 0
            s.acOutW = first(["inv.outputWatts"]) ?? s.totalOutW
            s.chgRemainMin = first(["ems.chgRemainTime", "bms_emsStatus.chgRemainTime", "pd.remainTime"])
            s.dsgRemainMin = first(["ems.dsgRemainTime", "bms_emsStatus.dsgRemainTime", "pd.remainTime"])
            s.tempC = first(["bmsMaster.temp", "bms_bmsStatus.temp", "inv.outTemp"])
        }
        if s.soc == nil { throw EFError.msg(L.t("no charge level in the response (unsupported model?)", "у відповіді нема заряду (непідтримувана модель?)")) }
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
    @Published var devices: [Device] = []
    @Published var snaps: [String: Snapshot] = [:]
    @Published var selectedSN: String?
    @Published var error: String?
    @Published var editMax = 100
    @Published var editMin = 10
    @Published var editSpeed = 1550
    @Published var busy = false
    @Published var result: [String] = []

    static let maxRange = 50...100, minRange = 0...30, speedRange = 200...2900
    static let maxDevices = 8                       // стеля запитів за хвилину: по одному на пристрій
    private var devicesFetched = Date.distantPast
    private let defaults = UserDefaults.standard

    init() { selectedSN = defaults.string(forKey: "selectedSN") }

    /// Обраний пристрій (його показує картка, ним керуємо).
    var snap: Snapshot? { selectedSN.flatMap { snaps[$0] } }
    var selectedDevice: Device? { devices.first { $0.sn == selectedSN } }
    var title: String { selectedDevice?.name ?? "EcoFlow" }

    /// Які пристрої виносити в менюбар (правий клік → меню). Порожньо = лише обраний.
    var pinned: [String] {
        get { defaults.stringArray(forKey: "pinnedSNs") ?? [] }
        set { defaults.set(newValue, forKey: "pinnedSNs") }
    }
    var menubarSNs: [String] {
        let live = pinned.filter { sn in devices.contains { $0.sn == sn } }
        return live.isEmpty ? [selectedSN].compactMap { $0 } : live
    }

    func select(_ sn: String) {
        guard sn != selectedSN, !busy else { return }
        selectedSN = sn
        defaults.set(sn, forKey: "selectedSN")
        result = []
        syncEdits(force: true)
    }

    func togglePinned(_ sn: String) {
        var p = menubarSNs
        if let i = p.firstIndex(of: sn) { if p.count > 1 { p.remove(at: i) } } else { p.append(sn) }
        pinned = p
    }

    var isStale: Bool { snap.map { Date().timeIntervalSince($0.fetched) > 300 } ?? true }

    var dirty: Bool {
        guard let s = snap, s.supportsControls else { return false }
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
        // Список пристроїв: раз на 10 хв (або поки порожній). Не вдалось і є серійник у Keychain = працюємо з ним.
        if devices.isEmpty || Date().timeIntervalSince(devicesFetched) > 600 {
            do {
                let list = Array(try await EcoFlowAPI.devices(cfg).prefix(Model.maxDevices))
                if !list.isEmpty { devices = list; devicesFetched = Date() }
            } catch {
                if devices.isEmpty, let sn = cfg.sn { devices = [Device(sn: sn, name: "EcoFlow", online: true, product: "")] }
                else if devices.isEmpty { self.error = error.localizedDescription; return false }
            }
            if devices.isEmpty, let sn = cfg.sn { devices = [Device(sn: sn, name: "EcoFlow", online: true, product: "")] }
        }
        if selectedSN == nil || !devices.contains(where: { $0.sn == selectedSN }) {
            selectedSN = (cfg.sn.flatMap { s in devices.first { $0.sn == s }?.sn }) ?? devices.first?.sn
        }
        let wasClean = !dirty
        var firstError: String?
        // Усі пристрої паралельно: у панелі видно заряд кожного, в менюбарі можна закріпити будь-який.
        let results = await withTaskGroup(of: (String, Result<Snapshot, Error>).self) { group -> [(String, Result<Snapshot, Error>)] in
            for d in devices {
                group.addTask {
                    do { return (d.sn, .success(try await EcoFlowAPI.fetch(cfg, sn: d.sn))) }
                    catch { return (d.sn, .failure(error)) }
                }
            }
            var out: [(String, Result<Snapshot, Error>)] = []
            for await r in group { out.append(r) }
            return out
        }
        for (sn, r) in results {
            switch r {
            case .success(let s): snaps[sn] = s
            case .failure(let e): if sn == selectedSN { firstError = e.localizedDescription }
            }
        }
        error = firstError
        if wasClean { syncEdits() }
        return firstError == nil
    }

    /// Записати лише змінене й ПЕРЕВІРИТИ зчитуванням: «Success» від EcoFlow нічого не доводить.
    func apply() async {
        guard let cfg = EFConfig.load(), let s = snap, s.supportsControls, let sn = selectedSN, !busy else { return }
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
                try await EcoFlowAPI.put(cfg, body: ["sn": sn, "operateType": "TCP", "params": job.params])
            } catch {
                result.append("⚠️ \(job.name): \(error.localizedDescription)")
                continue
            }
            var confirmed = false
            for _ in 0..<10 {                              // станція застосовує не миттєво
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let fresh = try? await EcoFlowAPI.fetch(cfg, sn: sn) {
                    snaps[sn] = fresh
                    if job.read(fresh) == job.target { confirmed = true; break }
                }
            }
            result.append(confirmed ? L.t("✓ \(job.name): confirmed by the station", "✓ \(job.name): станція підтвердила")
                                    : L.t("⚠️ \(job.name): not confirmed within 20 s", "⚠️ \(job.name): станція не підтвердила за 20 с"))
        }
        syncEdits(force: true)
    }
}
