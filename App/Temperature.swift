import Foundation

/// Temperatures are °C everywhere inside the app. This is the one place that converts for display.
enum Temperature {
    static func displayed(_ celsius: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    static func celsius(fromDisplayed value: Double, fahrenheit: Bool) -> Double {
        fahrenheit ? (value - 32) * 5 / 9 : value
    }

    static func string(_ celsius: Double?, fahrenheit: Bool) -> String {
        guard let celsius else { return "–" }
        return "\(Int(displayed(celsius, fahrenheit: fahrenheit).rounded()))°" + (fahrenheit ? "F" : "")
    }
}
