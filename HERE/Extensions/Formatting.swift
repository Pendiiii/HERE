import Foundation
import SwiftUI

extension Color {
    static let hereAccent = Color(red: 0.12, green: 0.42, blue: 0.96)
    static let hereCard = Color(uiColor: .secondarySystemBackground)
}

enum HEREFormatting {
    static func distance(_ meters: Int) -> String {
        let safe = max(0, meters)
        if safe < 100 { return "unter 100 m" }
        if safe < 1_000 { return "ca. \((safe / 50) * 50) m" }
        return String(format: "ca. %.1f km", Double(safe) / 1_000)
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "gerade eben" }
        if minutes < 60 { return "vor \(minutes) Min."
        }
        let hours = minutes / 60
        return "vor \(hours) Std."
    }
}

extension Array {
    func uniqued<ID: Hashable>(by keyPath: KeyPath<Element, ID>) -> [Element] {
        var seen = Set<ID>()
        return filter { seen.insert($0[keyPath: keyPath]).inserted }
    }
}
