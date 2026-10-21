import Foundation

/// Sanity check between a raw transcript and its polished rewrite. Polish is
/// allowed to compress (fillers, "for example" -> "e.g.", lists, digits) and to
/// repair misheard words, but not to answer the dictation, invent content, or
/// drop most of what was said. A rejected polish is replaced by the raw text.
public enum PolishGuard {
    public struct Verdict: Sendable, Equatable {
        public var accepted: Bool
        public var reason: String
        public var lengthRatio: Double
        public var coverage: Double
    }

    /// Bounds on polished/raw word counts once the raw text is long enough to judge.
    static let minimumRatio = 0.35
    static let maximumRatio = 1.6
    /// Share of the raw text's content words that must survive into the polish.
    static let minimumCoverage = 0.5

    public static func evaluate(raw: String, polished: String) -> Verdict {
        let rawWords = words(raw)
        let polishedWords = words(polished)
        let ratio = rawWords.isEmpty ? 0 : Double(polishedWords.count) / Double(rawWords.count)
        func verdict(_ accepted: Bool, _ reason: String, coverage: Double = 1) -> Verdict {
            Verdict(accepted: accepted, reason: reason, lengthRatio: ratio, coverage: coverage)
        }
        if polishedWords.isEmpty {
            return verdict(rawWords.isEmpty, "empty_polish")
        }
        if startsLikeAnAssistant(polished) && !startsLikeAnAssistant(raw) {
            return verdict(false, "assistant_preamble")
        }
        // Short dictations: only catch an answer or essay where a phrase was spoken.
        if rawWords.count < 6 {
            return verdict(polishedWords.count <= rawWords.count * 4 + 8, "short_expansion")
        }
        if ratio > maximumRatio { return verdict(false, "expanded") }
        if ratio < minimumRatio { return verdict(false, "dropped_content") }

        let content = rawWords.filter(isContentWord)
        // Mixed-script repair transliterates words, so only Latin-script content
        // is comparable; skip coverage when too little of it exists.
        let comparable = content.filter { $0.unicodeScalars.allSatisfy(\.isASCII) }
        guard comparable.count >= 4 else { return verdict(true, "ok") }
        let available = Set(polishedWords.flatMap(equivalents))
        let kept = comparable.filter { word in equivalents(word).contains(where: available.contains) }
        let coverage = Double(kept.count) / Double(comparable.count)
        return verdict(coverage >= minimumCoverage, coverage >= minimumCoverage ? "ok" : "low_coverage", coverage: coverage)
    }

    /// Lowercased letter/number tokens. "@src/auth.ts" yields src, auth, ts.
    static func words(_ text: String) -> [String] {
        normalizeForComparison(text).split(separator: " ").map(String.init)
    }

    private static func isContentWord(_ word: String) -> Bool {
        word.count >= 3 && !stopWords.contains(word)
    }

    /// A word and the forms polish may legitimately turn it into.
    private static func equivalents(_ word: String) -> [String] {
        var forms = [word]
        if let digit = numberWords[word] { forms.append(digit) }
        if word.count > 3, word.hasSuffix("s") { forms.append(String(word.dropLast())) }
        return forms
    }

    private static func startsLikeAnAssistant(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return assistantOpenings.contains { lowered.hasPrefix($0) }
    }

    private static let assistantOpenings = [
        "sure,", "sure!", "sure.", "certainly", "of course", "here is ", "here's ", "here are ",
        "as an ai", "i'm sorry", "i am sorry", "i can't", "i cannot", "absolutely!",
    ]

    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
        "thirteen": "13", "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30", "forty": "40",
        "fifty": "50", "sixty": "60", "seventy": "70", "eighty": "80", "ninety": "90",
        "hundred": "100", "thousand": "1000", "first": "1", "second": "2", "third": "3",
    ]

    private static let stopWords: Set<String> = [
        "the", "and", "but", "for", "with", "from", "this", "that", "these", "those", "there",
        "here", "what", "which", "who", "whom", "whose", "when", "where", "why", "how", "are",
        "was", "were", "been", "being", "have", "has", "had", "having", "does", "did", "doing",
        "will", "would", "should", "could", "can", "may", "might", "must", "shall", "you", "your",
        "yours", "they", "them", "their", "she", "her", "him", "his", "its", "our", "ours",
        "not", "just", "like", "really", "very", "also", "then", "than", "too", "into", "onto",
        "about", "some", "any", "all", "each", "other", "such", "only", "own", "same", "out",
        "over", "under", "again", "once", "now", "yeah", "okay", "well", "actually", "basically",
        "literally", "please", "um", "uh", "umm", "uhh", "hmm", "mmm", "erm", "kind", "sort",
        "going", "gonna", "wanna", "gotta", "let", "lets", "get", "got", "say", "said", "know",
        "mean", "thing", "things", "stuff", "dot", "slash", "comma", "period", "colon",
    ]
}
