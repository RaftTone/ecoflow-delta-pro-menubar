// EcoFlowBar: вузький показник заряду EcoFlow у менюбарі macOS + картка по кліку з керуванням.
//
// Іконка: кільце-шкала з числом (Look.swift), шаблонна, тож macOS сама робить її білою/чорною.
// Клік: popover із карткою за мотивами застосунку EcoFlow (Card.swift) і керуванням межами та швидкістю.
// Правий клік: «Оновити» / «Вийти».
//
// Дані й запис: Model.swift (ключі лише в Keychain: service ua.rafttone.ecoflowbar, account ecoflow).
//
// Прапори без UI: --once (опитати й надрукувати), --render <тека> (прев'ю іконки),
// --cards <тека> (PNG картки: темна/світла, кілька станів).

import AppKit
import SwiftUI

@MainActor
final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var items: [String: NSStatusItem] = [:]       // за серійником: по одному елементу на закріплений пристрій
    let model = Model()
    let popover = NSPopover()
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        let card = CardView(model: model, onRefresh: { [weak self] in self?.refreshNow() }, onQuit: { NSApp.terminate(nil) })
        let host = NSHostingController(rootView: card)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        redraw()
        refreshNow()
        if CommandLine.arguments.contains("--open-popup") {                         // для перевірки без миші
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self = self, let b = self.items.values.first?.button else { return }
                self.model.syncEdits()
                self.popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            }
        }
    }

    /// Елементи менюбару = закріплені пристрої (або лише обраний). Зайві знімаємо, потрібні створюємо.
    func syncItems() {
        let want = model.menubarSNs.isEmpty ? ["_none"] : model.menubarSNs
        for sn in items.keys where !want.contains(sn) {
            NSStatusBar.system.removeStatusItem(items[sn]!)
            items[sn] = nil
        }
        for (idx, sn) in want.enumerated() where items[sn] == nil {
            let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            // Перший елемент лишає стару назву, щоб macOS пам'ятала його місце; без autosaveName macOS 26 лишає «привидів» Item-N.
            it.autosaveName = idx == 0 ? "ua.rafttone.ecoflowbar" : "ua.rafttone.ecoflowbar.\(sn)"
            if let b = it.button {
                b.imagePosition = .imageOnly
                b.target = self
                b.action = #selector(clicked(_:))
                b.sendAction(on: [.leftMouseUp, .rightMouseUp])
                b.identifier = NSUserInterfaceItemIdentifier(sn)
            }
            items[sn] = it
        }
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let m = NSMenu()
            let r = NSMenuItem(title: L.t("Refresh", "Оновити"), action: #selector(menuRefresh), keyEquivalent: "r"); r.target = self
            m.addItem(r)
            if model.devices.count > 1 {
                m.addItem(.separator())
                let head = NSMenuItem(title: L.t("Show in menu bar", "Показувати в менюбарі"), action: nil, keyEquivalent: ""); head.isEnabled = false
                m.addItem(head)
                for d in model.devices {
                    let it = NSMenuItem(title: d.name, action: #selector(togglePin(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = d.sn
                    it.state = model.menubarSNs.contains(d.sn) ? .on : .off
                    m.addItem(it)
                }
                m.addItem(.separator())
            }
            m.addItem(NSMenuItem(title: L.t("Quit", "Вийти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            if let it = items.values.first(where: { $0.button === sender }) {
                it.menu = m
                sender.performClick(nil)
                it.menu = nil
            }
            return
        }
        if let sn = sender.identifier?.rawValue, sn != "_none" { model.select(sn) }   // клік по елементу обирає його пристрій
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if model.snap == nil || Date().timeIntervalSince(model.snap!.fetched) > 20 { refreshNow() }
            model.syncEdits()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func menuRefresh() { refreshNow() }

    @objc func togglePin(_ sender: NSMenuItem) {
        guard let sn = sender.representedObject as? String else { return }
        model.togglePinned(sn)
        redraw()
    }

    func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
    }

    func refreshNow() {
        Task {
            let ok = await model.refresh()
            redraw()
            schedule(ok ? 60 : 180)
        }
    }

    func redraw() {
        syncItems()
        for (sn, it) in items {
            guard let b = it.button else { continue }
            let s = model.snaps[sn] ?? (sn == "_none" ? model.snap : nil)
            b.image = Look.battery(soc: s?.soc, bolt: s?.charging ?? false)
            b.title = ""
            let name = model.devices.first { $0.sn == sn }?.name ?? "EcoFlow"
            b.toolTip = s?.soc.map { "\(name): \(Int($0.rounded()))%" } ?? "\(name): " + L.t("no data", "даних нема")
            b.appearsDisabled = s.map { Date().timeIntervalSince($0.fetched) > 300 } ?? true     // застарілі дані = притемнено
        }
    }
}

// MARK: - Рендер картки без екрана

@MainActor
func renderCards(to dir: URL) {
    func fake(soc: Double, grid: Bool, dirty: Bool, multi: Bool = false) -> Model {
        let m = Model()
        var s = Snapshot()
        s.soc = soc; s.socMaster = soc + 2; s.socSlave = soc - 1
        s.xboost = true; s.tempC = 26; s.supportsControls = true
        s.maxSoc = 100; s.minSoc = 10; s.acChargeW = 1550
        if grid {
            s.acInW = 1480; s.acInV = 230; s.acOutW = 120; s.totalOutW = 126; s.usb1 = 6
            s.chgRemainMin = 195; s.dsgRemainMin = 5000
        } else {
            s.acOutW = 503; s.totalOutW = 508; s.dsgRemainMin = 649; s.chgRemainMin = 15000; s.dc12W = 0; s.c1 = 5
        }
        m.devices = [Device(sn: "A", name: "DELTA Pro", online: true, product: "")]
        m.snaps["A"] = s
        m.selectedSN = "A"
        if multi {
            var r = Snapshot(); r.soc = 88; r.acOutW = 40; r.totalOutW = 42; r.dsgRemainMin = 540; r.tempC = 24
            var g = Snapshot(); g.soc = 41; g.acInW = 300; g.totalOutW = 60; g.chgRemainMin = 130; g.tempC = 22
            m.devices += [Device(sn: "B", name: "River 2", online: true, product: ""), Device(sn: "C", name: "Garage", online: false, product: "")]
            m.snaps["B"] = r; m.snaps["C"] = g
        }
        m.syncEdits(force: true)
        if dirty { m.editMax = 90; m.editMin = 15; m.editSpeed = 2000 }
        return m
    }
    let multi = fake(soc: 73, grid: false, dirty: false, multi: true)
    multi.selectedSN = "B"                                   // обрано модель без керування: картка лише читає
    let cases: [(String, Model)] = [("blackout", fake(soc: 73, grid: false, dirty: false)),
                                    ("grid", fake(soc: 34, grid: true, dirty: false)),
                                    ("edit", fake(soc: 73, grid: false, dirty: true)),
                                    ("multi-delta", fake(soc: 73, grid: false, dirty: false, multi: true)),
                                    ("multi-readonly", multi)]
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, model) in cases {
        for (scheme, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", NSAppearance.Name.aqua)] {
            let host = NSHostingView(rootView: CardView(model: model, opaque: true).fixedSize(horizontal: false, vertical: true))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 320, height: 10)
            let h = host.fittingSize.height
            host.frame = NSRect(x: 0, y: 0, width: 320, height: h)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            rep.size = host.bounds.size
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("card-\(name)-\(scheme).png"))
            }
        }
    }
    print("cards written to \(dir.path)")
}

// MARK: - Точка входу

let args = CommandLine.arguments

if let i = args.firstIndex(of: "--render") {
    let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : ".")
    _ = NSApplication.shared
    let st: [(String, Double?, Bool, Bool)] = [("charging", 100, true, false), ("74%", 74, false, false), ("34%", 34, true, false),
                                                ("12%", 12, false, false), ("3%", 3, false, false), ("stale", 74, false, true)]
    Look.preview(states: st, to: dir)
    Look.preview(states: st, to: dir, scale: 2, name: "ecoflowbar-real2x.png")      // справжні пікселі ретіни
    print("preview written to \(dir.path)/ecoflowbar-preview.png and ecoflowbar-real2x.png")
    exit(0)
}

if let i = args.firstIndex(of: "--cards") {
    let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : ".")
    _ = NSApplication.shared
    MainActor.assumeIsolated { renderCards(to: dir) }
    exit(0)
}

if args.contains("--once") {
    guard let cfg = EFConfig.load() else { print("no keys in Keychain"); exit(2) }
    let sem = DispatchSemaphore(value: 0)
    Task {
        do {
            var list = try await EcoFlowAPI.devices(cfg)
            if list.isEmpty, let sn = cfg.sn { list = [Device(sn: sn, name: "EcoFlow", online: true, product: "")] }
            print("devices: \(list.count)")
            for d in list {
                do {
                    let s = try await EcoFlowAPI.fetch(cfg, sn: d.sn)
                    print("\(d.name) [\(d.sn.prefix(4))…] soc=\(s.soc ?? -1) batteries=\(s.socMaster ?? -1)/\(s.socSlave ?? -1) INPUT=\(s.externalInW) (grid \(s.acInW), Tesla/DC \(s.dcInW)) OUTPUT=\(s.totalOutW) AC=\(s.acOutW) | controls=\(s.supportsControls) limits \(s.minSoc ?? -1)…\(s.maxSoc ?? -1)% speed \(s.acChargeW ?? -1) W | remaining \(s.dsgRemainMin ?? -1) min")
                } catch { print("\(d.name): ERROR \(error.localizedDescription)") }
            }
        } catch { print("ERROR: \(error.localizedDescription)") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = App()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
