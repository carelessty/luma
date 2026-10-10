import Foundation

struct SubtitleCue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

/// A compact WebVTT index. Seeking uses binary search, including overlapping cues.
struct SubtitleDocument {
    let cues: [SubtitleCue]
    private let latestEnd: [TimeInterval]

    init(webVTT source: String) {
        let source = source.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parsed: [SubtitleCue] = []
        for block in source.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let first = lines.first,
                  !first.hasPrefix("NOTE"), !first.hasPrefix("STYLE"), !first.hasPrefix("REGION"),
                  let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let times = lines[timingIndex].components(separatedBy: "-->")
            guard times.count == 2,
                  let start = Self.timestamp(times[0].trimmingCharacters(in: .whitespaces)),
                  let endToken = times[1].split(whereSeparator: { $0.isWhitespace }).first,
                  let end = Self.timestamp(String(endToken)), end > start else { continue }
            let text = Self.plainText(lines.dropFirst(timingIndex + 1).joined(separator: "\n"))
            if !text.isEmpty { parsed.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        cues = parsed.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var maximum: TimeInterval = 0
        latestEnd = cues.map { maximum = max(maximum, $0.end); return maximum }
    }

    func text(at seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, !cues.isEmpty else { return "" }
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].start <= seconds { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        var active: [String] = []
        while index >= 0, latestEnd[index] > seconds {
            if cues[index].end > seconds { active.append(cues[index].text) }
            index -= 1
        }
        return active.reversed().joined(separator: "\n")
    }

    private static func timestamp(_ raw: String) -> TimeInterval? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!),
              seconds.isFinite, seconds >= 0, seconds < 60,
              let minutes = Int(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        var hours = 0
        if parts.count == 3 {
            guard let value = Int(parts[0]), value >= 0 else { return nil }
            hours = value
        }
        let result = Double(hours) * 3_600 + Double(minutes) * 60 + seconds
        return result.isFinite ? result : nil
    }

    private static func plainText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&lrm;", "\u{200E}"),
                                ("&rlm;", "\u{200F}"), ("&quot;", "\""), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        if let expression = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let valueRange = Range(match.range(at: 1), in: text),
                      let fullRange = Range(match.range, in: text) else { continue }
                let value = String(text[valueRange])
                let number = value.hasPrefix("x") ? UInt32(value.dropFirst(), radix: 16) : UInt32(value)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(fullRange, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
