// Картка по кліку (SwiftUI у NSPopover): за мотивами застосунку EcoFlow, але українською, і «Вхід» лише зовнішній.

import SwiftUI

extension Color {
    static let efGreen = Color(red: 0.20, green: 0.80, blue: 0.45)
    static let efOrange = Color(red: 1.0, green: 0.69, blue: 0.16)
    static let efBlue = Color(red: 0.27, green: 0.42, blue: 0.96)
}

// MARK: - Дрібні елементи

private struct Tile<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ c: () -> Content) { content = c() }
    var body: some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// Власна кнопка замість системної: однаково поводиться в popover і в офскрін-рендері.
private struct Chip: View {
    let title: String
    var filled = false
    var tint: Color = .efGreen
    var enabled = true
    var small = false
    let action: () -> Void
    var body: some View {
        Text(title)
            .font(.system(size: small ? 11 : 12, weight: .semibold, design: .rounded))
            .foregroundStyle(filled && enabled ? Color.black.opacity(0.85) : (enabled ? Color.primary : Color.secondary))
            .padding(.horizontal, small ? 8 : 11).padding(.vertical, small ? 3 : 5)
            .background(Capsule().fill(filled && enabled ? tint : Color.primary.opacity(0.10)))
            .contentShape(Capsule())
            .onTapGesture { if enabled { action() } }
    }
}

private struct RoundButton: View {
    let symbol: String
    var enabled = true
    var size: CGFloat = 22
    let action: () -> Void
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.primary.opacity(0.10)))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Circle())
            .onTapGesture { if enabled { action() } }
    }
}

/// Шкала заряду з двома ручками меж: тягни «Розряд до» (0…30) і «Заряд до» (50…100) прямо по батареї, крок 5%.
/// Змінене лише ПРОПОНУЄТЬСЯ (помаранчеве); у станцію піде після «Застосувати».
private struct BatteryBar: View {
    let soc: Double
    @Binding var minSoc: Int
    @Binding var maxSoc: Int
    var pending = false
    var enabled = true
    @State private var active: Int?            // 0 = нижня ручка, 1 = верхня

    private let barH: CGFloat = 24

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let x: (Double) -> CGFloat = { CGFloat(min(100, max(0, $0))) / 100 * w }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: barH)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [Color.efGreen.opacity(0.95), Color.efGreen.opacity(0.62)], startPoint: .top, endPoint: .bottom))
                    .frame(width: max(12, x(soc)), height: barH)
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.white.opacity(0.35)).frame(height: 1.2).padding(.horizontal, 6).padding(.top, 2)
                    }
                // пунктир від ручки вниз
                dash(at: x(Double(minSoc)))
                dash(at: x(Double(maxSoc)))
                // поточний заряд
                HStack(spacing: 3) {
                    Image(systemName: "arrowtriangle.up.fill").font(.system(size: 6)).foregroundStyle(.secondary)
                    Text(verbatim: "\(Int(soc.rounded()))%").font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .fixedSize()
                .position(x: min(max(x(soc), 22), w - 22), y: barH + 10)
                // підписи меж
                label(L.t("Discharge to", "Розряд до"), minSoc, leading: true).offset(x: min(max(x(Double(minSoc)) + 7, 0), w - 96), y: barH + 22)
                label(L.t("Charge to", "Заряд до"), maxSoc, leading: false).offset(x: min(max(x(Double(maxSoc)) - 103, 0), w - 96), y: barH + 22)
                // ручки
                knob(at: x(Double(minSoc)), isActive: active == 0)
                knob(at: x(Double(maxSoc)), isActive: active == 1)
                // перехоплення жесту по всій зоні
                Rectangle().fill(Color.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard enabled else { return }
                            if active == nil {
                                active = abs(v.startLocation.x - x(Double(minSoc))) <= abs(v.startLocation.x - x(Double(maxSoc))) ? 0 : 1
                            }
                            let pct = Int((v.location.x / max(w, 1) * 100 / 5).rounded()) * 5
                            if active == 0 { minSoc = min(30, max(0, pct)) } else { maxSoc = min(100, max(50, pct)) }
                        }
                        .onEnded { _ in active = nil })
            }
        }
        .frame(height: barH + 40)
    }

    private func dash(at x: CGFloat) -> some View {
        Path { p in p.move(to: CGPoint(x: x, y: barH)); p.addLine(to: CGPoint(x: x, y: barH + 36)) }
            .stroke(pending ? Color.efOrange : Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
    }

    private func knob(at x: CGFloat, isActive: Bool) -> some View {
        Capsule()
            .fill(pending ? Color.efOrange : Color.white)
            .overlay(Capsule().stroke(Color.black.opacity(0.28), lineWidth: 0.8))
            .frame(width: isActive ? 8 : 6, height: barH + 8)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .position(x: x, y: barH / 2)
    }

    private func label(_ title: String, _ value: Int, leading: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(verbatim: "\(value)%").font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(pending ? Color.efOrange : Color.primary)
        }
        .fixedSize()
        .frame(width: 96, alignment: leading ? .leading : .trailing)
    }
}

// MARK: - Картка

struct CardView: View {
    @ObservedObject var model: Model
    var opaque = false                       // для офскрін-рендеру: суцільний фон замість матеріалу popover
    var onRefresh: () -> Void = {}
    var onQuit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let s = model.snap {
                hero(s)
                BatteryBar(soc: s.soc ?? 0, minSoc: $model.editMin, maxSoc: $model.editMax,
                           pending: model.dirty, enabled: !model.busy)
                flows(s)
                ports(s)
                controls(s)
            } else {
                Text(model.error ?? L.t("Loading…", "Завантажую…")).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(opaque ? Color(nsColor: .windowBackgroundColor) : Color.clear)
    }

    // — шапка
    private var header: some View {
        HStack(spacing: 6) {
            Text("EcoFlow DELTA Pro").font(.system(size: 13, weight: .semibold, design: .rounded))
            Circle().fill(model.isStale ? Color.efOrange : Color.efGreen).frame(width: 6, height: 6)
            Spacer()
            if let t = model.snap?.tempC {
                Label(String(Int(t.rounded())) + " °C", systemImage: "thermometer.medium")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    // — запас часу
    private func hero(_ s: Snapshot) -> some View {
        let (label, mins, text) = heroParts(s)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let m = mins {
                    let h = Int(m) / 60, mm = Int(m) % 60
                    if h > 0 { big(String(h)); unit(L.hour) }
                    big(h > 0 ? String(format: "%02d", mm) : String(mm)); unit(L.minute)
                } else {
                    big(text ?? "–", long: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func heroParts(_ s: Snapshot) -> (String, Double?, String?) {
        if s.charging {
            if (s.soc ?? 0) >= 99 { return (L.t("Battery", "Заряд"), nil, L.t("Full", "Повна")) }
            if let m = s.chgRemainMin, m > 0, m < 48 * 60 { return (L.t("To full", "До повної"), m, nil) }
            return (L.t("Battery", "Заряд"), nil, L.t("Charging", "Заряджається"))
        }
        if let m = s.dsgRemainMin, m > 0, m < 96 * 60 { return (L.t("Remaining", "Залишилось"), m, nil) }
        return (L.t("Remaining", "Залишилось"), nil, L.t("unreliable estimate", "оцінка недостовірна"))
    }

    private func big(_ t: String, long: Bool = false) -> some View {
        Text(verbatim: t).font(.system(size: long ? 16 : 28, weight: .heavy, design: .rounded)).monospacedDigit()
    }
    private func unit(_ t: String) -> some View {
        Text(t).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(.secondary).padding(.trailing, 4)
    }

    // — вхід / вихід
    private func flows(_ s: Snapshot) -> some View {
        HStack(alignment: .top, spacing: 10) {
            flow(L.t("Input", "Вхід"), watts: s.externalInW, note: inputNote(s), color: .secondary, line: Color.primary.opacity(0.15))
            flow(L.t("Output", "Вихід"), watts: s.totalOutW, note: "", color: .efOrange, line: .efOrange)
        }
    }

    private func flow(_ title: String, watts: Double, note: String, color: Color, line: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                Spacer()
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(verbatim: String(Int(watts.rounded()))).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                Text(L.w).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Rectangle().fill(line).frame(height: 1.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputNote(_ s: Snapshot) -> String {
        if s.charging {
            var parts: [String] = []
            if s.acInW > 5 { parts.append(L.t("grid", "мережа")) }
            if s.dcInW > 5 { parts.append("Tesla") }
            return parts.joined(separator: " + ")
        }
        return L.t("no mains", "мережі немає")
    }

    // — порти (AC і решта в одній плитці)
    private func ports(_ s: Snapshot) -> some View {
        let items: [(String, Double)] = [("USB-A", s.usb1), ("USB-A", s.usb2), ("FAST", s.qc1), ("FAST", s.qc2),
                                         ("Type-C", s.c1), ("Type-C", s.c2), ("12V DC", s.dc12W), ("12V 30A", s.carW)]
        return Tile {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("AC").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(verbatim: "\(Int(s.acOutW.rounded())) \(L.w)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(s.acOutW > 0 ? Color.efOrange : Color.primary)
                    Spacer()
                    if s.xboost {
                        Text("X-Boost").font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.efBlue)).foregroundStyle(.white)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                        HStack(spacing: 3) {
                            Text(it.0).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            Text(verbatim: String(Int(it.1.rounded())))
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(it.1 > 0 ? Color.efOrange : Color.secondary.opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    // — керування: межі тягнуться по шкалі, тут швидкість і «Застосувати»
    private func controls(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Tile {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(L.t("Charging speed", "Швидкість зарядки")).font(.system(size: 12))
                        Spacer()
                        RoundButton(symbol: "minus", enabled: model.editSpeed > Model.speedRange.lowerBound && !model.busy) {
                            model.editSpeed = max(Model.speedRange.lowerBound, model.editSpeed - 100)
                        }
                        Text(verbatim: "\(model.editSpeed) \(L.w)").font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            .frame(minWidth: 58)
                        RoundButton(symbol: "plus", enabled: model.editSpeed < Model.speedRange.upperBound && !model.busy) {
                            model.editSpeed = min(Model.speedRange.upperBound, model.editSpeed + 100)
                        }
                    }
                    HStack(spacing: 5) {
                        ForEach([500, 1000, 1500, 2900], id: \.self) { w in
                            Chip(title: String(w), filled: model.editSpeed == w, small: true) { model.editSpeed = w }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            HStack(spacing: 6) {
                if model.dirty || model.busy {
                    Chip(title: model.busy ? L.t("Applying…", "Застосовую…") : L.t("Apply", "Застосувати"), filled: true, enabled: model.dirty && !model.busy) {
                        Task { await model.apply() }
                    }
                    if !model.busy { Chip(title: L.t("Cancel", "Скасувати")) { model.syncEdits(force: true) } }
                } else {
                    Text(L.t("Drag the limits on the battery", "Тягни межі на шкалі заряду")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ForEach(Array(model.result.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 10)).foregroundStyle(line.hasPrefix("✓") ? Color.efGreen : Color.efOrange)
            }
        }
    }

    // — підвал
    private var footer: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if let e = model.error { Text("⚠️ \(e)").font(.system(size: 10)).foregroundStyle(Color.efOrange) }
                if let t = model.snap?.fetched {
                    Text((model.isStale ? L.t("Data is stale, last at ", "Дані застаріли, останні о ") : L.t("Updated at ", "Оновлено о ")) + Self.clock.string(from: t))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            RoundButton(symbol: "arrow.clockwise", action: onRefresh)
            RoundButton(symbol: "power", action: onQuit)
        }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
