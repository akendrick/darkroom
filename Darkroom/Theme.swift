import SwiftUI

/// Which look is on. Observed, so every view using a Theme colour redraws
/// when it changes, without closing what's open.
@MainActor @Observable
final class Look {
    static let shared = Look()
    private static let key = "darkroomMode"
    var darkroom = UserDefaults.standard.bool(forKey: key) {
        didSet { UserDefaults.standard.set(darkroom, forKey: Self.key) }
    }
}

/// Two looks: everyday (dark ink on paper) and darkroom mode (red on black,
/// safe under the safelight), switched in Settings.
@MainActor
enum Theme {
    static var darkroom: Bool { Look.shared.darkroom }

    /// The main colour: text, headings, outlines.
    static var red: Color { darkroom ? Color(red: 1, green: 0.165, blue: 0.102)       // #ff2a1a
                                     : Color(red: 0.75, green: 0.11, blue: 0.06) }    // #bf1c0f
    static var dim: Color { darkroom ? red.opacity(0.55) : Color(red: 0.1, green: 0.1, blue: 0.08).opacity(0.6) }
    static var line: Color { red.opacity(0.45) }
    /// A chosen item.
    static var fill: Color { darkroom ? Color(red: 0.23, green: 0.02, blue: 0) : Color(red: 0.98, green: 0.88, blue: 0.86) }
    /// Fields: black text on it.
    static var box: Color { darkroom ? Color(red: 0.7, green: 0.1, blue: 0.05) : Color(red: 0.93, green: 0.91, blue: 0.89) }
    /// Field labels.
    static var bright: Color { darkroom ? Color(red: 1, green: 0.42, blue: 0.34) : Color(red: 0.45, green: 0.08, blue: 0.04) }
    /// Page background.
    static var bg: Color { darkroom ? .black : Color(red: 0.99, green: 0.98, blue: 0.97) }
    /// Text on the big red buttons.
    static var onRed: Color { darkroom ? .black : .white }

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy).width(.condensed) }
    static let body = Font.system(.body, design: .monospaced)
    static let small = Font.system(.footnote, design: .monospaced)
    static let label = Font.system(.caption, design: .monospaced).weight(.semibold)
}

/// Black with a red border and red text: Back, Skip, Start, Reset.
struct WalkButtonStyle: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.body.weight(.semibold))
            .foregroundStyle(Theme.red)
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(minHeight: 54)
            .background(on || configuration.isPressed ? Theme.fill : Theme.bg, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.red, lineWidth: 2))
    }
}

/// The biggest button: red with black text, at the bottom. Compact, it's the
/// size of a WalkButtonStyle button (the walk-through's Next beside Back).
struct NextButtonStyle: ButtonStyle {
    var compact = false
    /// Half as long again with bigger text, the same height (multi-print).
    var long = false
    func makeBody(configuration: Configuration) -> some View {
        if compact {
            configuration.label
                .font(long ? Theme.display(30) : Theme.body.weight(.heavy))
                .lineLimit(1)
                .foregroundStyle(Theme.onRed)
                .padding(.horizontal, 22).padding(.vertical, long ? 10 : 14)
                .frame(minWidth: long ? 165 : nil, minHeight: 54)
                .background(Theme.red.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 10))
        } else {
            configuration.label
                .font(Theme.display(34))
                .tracking(2)
                .lineLimit(1).minimumScaleFactor(0.6)
                .foregroundStyle(Theme.onRed)
                .frame(maxWidth: .infinity, minHeight: 78)
                .background(Theme.red.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 12))
        }
    }
}

/// A labelled field: a light red label over black text on dark red, easy
/// to read at a glance under the safelight.
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
            content
                .font(Theme.body.weight(.bold)).foregroundStyle(.black).tint(.black)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .background(Theme.box, in: .rect(cornerRadius: 8))
        }
    }
}

/// Hours, minutes and seconds on scroll wheels: a quick flick, no typing.
struct TimeWheels: View {
    let seconds: Int
    let set: (Int) -> Void
    var body: some View {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        HStack(spacing: 0) {
            wheel(h, 0...24, "h") { set($0 * 3600 + m * 60 + s) }
            wheel(m, 0...59, "m") { set(h * 3600 + $0 * 60 + s) }
            wheel(s, 0...59, "s") { set(h * 3600 + m * 60 + $0) }
        }
        .frame(height: 130)
    }

    private func wheel(_ v: Int, _ range: ClosedRange<Int>, _ unit: String, _ change: @escaping (Int) -> Void) -> some View {
        Picker(unit, selection: Binding(get: { v }, set: change)) {
            ForEach(range, id: \.self) { Text("\($0) \(unit)").font(Theme.display(28)).foregroundStyle(.black).tag($0) }
        }
        .pickerStyle(.wheel).labelsHidden()
        .frame(maxWidth: .infinity).clipped()
    }
}
