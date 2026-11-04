import Foundation

/// Times are stored in seconds and typed as minutes ("10"), seconds ("90s"),
/// m:ss ("2:30"), hours ("2h", "1.5h", "2h30") or h:mm:ss ("2:30:00") —
/// the same rules as the web page.
enum Duration {
    enum Parsed: Equatable { case empty, seconds(Int), invalid }

    static func parse(_ text: String) -> Parsed {
        let v = text.trimmingCharacters(in: .whitespaces).lowercased()
        if v.isEmpty { return .empty }
        if let m = v.wholeMatch(of: /(\d+):([0-5]\d):([0-5]\d)/) {
            return .seconds(Int(m.1)! * 3600 + Int(m.2)! * 60 + Int(m.3)!)
        }
        if let m = v.wholeMatch(of: /(\d+):([0-5]?\d)/) {
            return .seconds(Int(m.1)! * 60 + Int(m.2)!)
        }
        // Any of hours, minutes, seconds in that order; a bare number is minutes.
        let hms = /(?:(\d+(?:\.\d+)?)\s*h(?:rs?|ours?)?\s*)?(?:(\d+(?:\.\d+)?)\s*(?:m|mins?|minutes?|(?=$))\s*)?(?:(\d+(?:\.\d+)?)\s*s(?:ecs?)?)?/
        if let m = v.wholeMatch(of: hms), m.1 != nil || m.2 != nil || m.3 != nil {
            let h = m.1.flatMap { Double($0) } ?? 0
            let mi = m.2.flatMap { Double($0) } ?? 0
            let s = m.3.flatMap { Double($0) } ?? 0
            return .seconds(Int((h * 3600 + mi * 60 + s).rounded()))
        }
        return .invalid
    }

    /// 0:12, 10:00, 2:30:00
    static func format(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
