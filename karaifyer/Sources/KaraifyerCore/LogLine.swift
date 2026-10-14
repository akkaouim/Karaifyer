import Foundation

/// Terminal rows start with the time they were logged (Michel: follow an overnight run).
public enum LogLine {
    public static func stamped(_ text: String, at date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let t = f.string(from: date)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { "\(t) \($0)" }.joined(separator: "\n")
    }
}
