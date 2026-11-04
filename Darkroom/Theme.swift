import SwiftUI

/// Darkroom-safe: red on black, as on the web walk-through.
enum Theme {
    static let red = Color(red: 1, green: 0.165, blue: 0.102)        // #ff2a1a
    static let dim = Color(red: 1, green: 0.165, blue: 0.102).opacity(0.55)
    static let line = Color(red: 1, green: 0.165, blue: 0.102).opacity(0.45)
    static let fill = Color(red: 0.23, green: 0.02, blue: 0)          // #3a0600, a chosen item

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
            .background(on || configuration.isPressed ? Theme.fill : .black, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.red, lineWidth: 2))
    }
}

/// The biggest button: red with black text, at the bottom.
struct NextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.display(34))
            .tracking(2)
            .lineLimit(1).minimumScaleFactor(0.6)
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 78)
            .background(Theme.red.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 12))
    }
}

/// A labelled field in red on black.
struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Theme.label).tracking(1.5).foregroundStyle(Theme.dim)
            content
                .font(Theme.body).foregroundStyle(Theme.red).tint(Theme.red)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
        }
    }
}
