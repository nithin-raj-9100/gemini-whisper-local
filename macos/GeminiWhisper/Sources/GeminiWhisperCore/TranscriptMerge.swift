import Foundation

/// Fewest milliseconds of voiced audio needed to say one word: about 400 words
/// per minute, faster than almost anyone dictates. A repeated final is only
/// treated as new speech when at least this much new audio could carry it.
public let MINIMUM_VOICED_MS_PER_WORD = 150

/// Whether `voicedMs` of new speech audio could plausibly have produced `text`.
public func newSpeechLikely(voicedMs: Int, incoming text: String) -> Bool {
    let words = transcriptWordCount(text)
    return words > 0 && voicedMs >= max(400, words * MINIMUM_VOICED_MS_PER_WORD)
}

/// Letter/number words, ignoring punctuation.
public func transcriptWordCount(_ text: String) -> Int {
    normalizeForComparison(text).split(separator: " ").count
}

public func transcriptDraft(finalSegments: [String], latestInterim: String, startsNewTurn: Bool = false) -> String {
    // A hypothesis can resend or extend finalized text. Use the same merge for
    // the preview and the final result, unless the protocol marked a new turn.
    let segments = startsNewTurn ? finalSegments + [latestInterim]
        : appendDedupedFinalSegment(finalSegments, latestInterim)
    return segments
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Transcript owned by one Live connection generation. Rotating to a new Live
/// session starts a new generation, so merging never compares text across
/// sessions and a late final from the retiring session lands in its own place.
struct GenerationTranscript {
    var segments: [String] = []
    var latestInterim = ""
    var startsNewTurn = false
    /// Voiced audio sent to this generation since its last final.
    var voicedMsSinceFinal = 0

    var draft: String {
        transcriptDraft(finalSegments: segments, latestInterim: latestInterim, startsNewTurn: startsNewTurn)
    }

    mutating func acceptFinal(_ text: String) {
        let fresh = newSpeechLikely(voicedMs: voicedMsSinceFinal, incoming: text)
        segments = startsNewTurn ? segments + [text]
            : appendDedupedFinalSegment(segments, text, newSpeechLikely: fresh)
        startsNewTurn = false
        latestInterim = ""
        voicedMsSinceFinal = 0
    }
}

func joinedDraft(_ generations: [GenerationTranscript]) -> String {
    generations.map(\.draft).filter { !$0.isEmpty }.joined(separator: "\n")
}

public func transcriptsCompatible(_ draft: String, _ final: String) -> Bool {
    !draft.isEmpty && draft == final
}

private func recognitionHypothesesSimilar(_ draft: String, _ final: String) -> Bool {
    let left = normalizeForComparison(draft)
    let right = normalizeForComparison(final)
    if left.isEmpty || right.isEmpty { return false }
    if left == right { return true }
    let leftWords = left.split(separator: " ").map(String.init)
    let rightWords = right.split(separator: " ").map(String.init)
    // If the final transcript has different word count (e.g. newly arrived end words),
    // speculative polish based on the draft cannot contain them. Never reuse in that case.
    if leftWords.count != rightWords.count { return false }
    let length = leftWords.count
    var matching = 0
    for index in 0..<length {
        if leftWords[index] == rightWords[index] {
            matching += 1
        }
    }
    return Double(matching) / Double(length) >= 0.9
}

public func extractTrailingExtension(prefix: String, full: String) -> String? {
    let left = normalizeForComparison(prefix)
    let right = normalizeForComparison(full)
    if left.isEmpty || right.isEmpty { return nil }
    let prefixWords = left.split(separator: " ").map(String.init)
    let fullWords = right.split(separator: " ").map(String.init)
    guard !prefixWords.isEmpty, fullWords.count > prefixWords.count else { return nil }
    let commonPrefix = zip(prefixWords, fullWords).prefix { $0.0 == $0.1 }.count
    if commonPrefix == prefixWords.count {
        let originalWords = full.split(separator: " ").map(String.init)
        if originalWords.count > commonPrefix {
            return originalWords.dropFirst(commonPrefix).joined(separator: " ")
        }
    }
    return nil
}

/// Normalized substring check (case/punctuation-insensitive). Used to detect
/// duplicate resends without comparing raw formatting.
public func normalizedTranscriptContains(haystack: String, needle: String) -> Bool {
    let hay = normalizeForComparison(haystack)
    let ndl = normalizeForComparison(needle)
    if hay.isEmpty || ndl.isEmpty { return false }
    if hay == ndl { return true }
    return (" " + hay + " ").contains(" " + ndl + " ")
}

/// Merge a newly arrived final chunk without duplicating text the session
/// already holds, and without deleting speech.
///
/// - A chunk that covers the trailing segments (a cumulative resend or an
///   extension) replaces them. Nothing is lost: the chunk contains them.
/// - A chunk already present at the tail of the transcript is a resend, unless
///   `newSpeechLikely` says enough new speech audio arrived to have said it again.
///   Earlier, non-trailing text never suppresses a chunk: repeating a phrase later
///   in a dictation is ordinary speech.
/// - A same-sentence rewording replaces the last segment only when no new speech
///   could account for it. Otherwise both are kept: a duplicate is visible and
///   polish removes accidental repeats, but a deletion cannot be recovered.
public func appendDedupedFinalSegment(_ segments: [String], _ text: String, newSpeechLikely: Bool = false) -> [String] {
    let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if incoming.isEmpty { return segments }
    if !newSpeechLikely, normalizedTranscriptContains(haystack: transcriptTail(segments, covering: incoming), needle: incoming) {
        return segments
    }
    // A cumulative final can cover several previously delivered windows.
    // Replace all covered trailing segments, not only the last one.
    for index in segments.indices {
        let suffix = segments[index...].joined(separator: "\n")
        if normalizedTranscriptContains(haystack: incoming, needle: suffix) {
            return Array(segments[..<index]) + [incoming]
        }
    }
    if !newSpeechLikely,
       let last = segments.last,
       !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       isRevisionReplacement(last: last, incoming: incoming)
    {
        // Live self-correction (e.g. "the the maid" -> "the"): same sentence
        // re-recognized with different words. Replace instead of keeping the
        // garbled hypothesis plus its correction as two paragraphs.
        var merged = segments
        merged[merged.count - 1] = incoming
        return merged
    }
    var merged = segments
    merged.append(incoming)
    return merged
}

/// The trailing words a resend could duplicate: the last segment, widened to
/// twice the incoming length so a resend spanning a segment boundary still matches.
private func transcriptTail(_ segments: [String], covering incoming: String) -> String {
    let words = segments.filter { !$0.isEmpty }.joined(separator: " ")
        .split(whereSeparator: { $0.isWhitespace })
    let lastWords = segments.last?.split(whereSeparator: { $0.isWhitespace }).count ?? 0
    let incomingWords = incoming.split(whereSeparator: { $0.isWhitespace }).count
    return words.suffix(max(lastWords, incomingWords * 2)).joined(separator: " ")
}

/// Same sentence re-recognized with different words (STT self-correction),
/// as opposed to genuinely new speech. Exact resends are handled by
/// containment checks; this catches same-length rewordings and
/// prefix/suffix-anchored revisions of different lengths.
public func isRevisionReplacement(last: String, incoming: String) -> Bool {
    if recognitionHypothesesSimilar(last, incoming) { return true }
    let old = normalizeForComparison(last).split(separator: " ").map(String.init)
    let new = normalizeForComparison(incoming).split(separator: " ").map(String.init)
    if old.isEmpty || new.isEmpty { return false }
    var prefix = 0
    while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < min(old.count - prefix, new.count - prefix),
          old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
    {
        suffix += 1
    }
    if prefix >= 2, suffix >= 2,
       prefix + suffix >= Int((Double(min(old.count, new.count)) * 0.6).rounded(.up))
    {
        return true
    }
    return false
}

private let nonWordPattern = try! NSRegularExpression(pattern: "[^\\p{L}\\p{N}]+")

func normalizeForComparison(_ text: String) -> String {
    let lowered = text.lowercased()
    let range = NSRange(lowered.startIndex..., in: lowered)
    let replaced = nonWordPattern.stringByReplacingMatches(in: lowered, range: range, withTemplate: " ")
    return replaced.trimmingCharacters(in: .whitespacesAndNewlines)
}
