import Foundation
import NaturalLanguage

// MARK: - SyllabificationService

/// Splits text into words using NLTokenizer and then hyphenates each word
/// into syllables using Liang's TeX hyphenation algorithm with bundled
/// `hyph-en-us.pat.txt` patterns (~5K patterns, public domain, ~98% accuracy).
///
/// Usage:
/// ```
/// let result = SyllabificationService.syllabify("Hello world amazing")
/// // → [("Hello", ["Hel", "lo"]), ("world", ["world"]), ("amazing", ["a", "maz", "ing"])]
/// ```
@available(macOS 26.0, *)
enum SyllabificationService {

    // MARK: - Public API

    /// Syllabifies text into an ordered array of (word, syllables) tuples.
    /// Strips direction markup (`[[...]]`) before tokenizing.
    /// - Parameter text: Raw lyrics/libretto text, possibly containing direction markup.
    /// - Returns: Array of (original word, syllable strings). Each syllable preserves
    ///   the original casing. Single-syllable words return `[word]`.
    static func syllabify(_ text: String) -> [(word: String, syllables: [String])] {
        var cleaned = DirectionParser.stripDirections(from: text)
        cleaned = stripCurlyBraceContent(cleaned)
        let words = tokenizeWords(cleaned)
        return words.map { word in
            let syllables = hyphenate(word)
            return (word, syllables)
        }
    }

    /// Strips all content inside `{...}` curly braces (stage directions, instructions).
    /// Handles nested braces and multiline content.
    private static func stripCurlyBraceContent(_ text: String) -> String {
        var result = ""
        var depth = 0
        for ch in text {
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth = max(0, depth - 1)
            } else if depth == 0 {
                result.append(ch)
            }
        }
        return result
    }

    /// Extracts only the sung/spoken lyrics from a full libretto text.
    ///
    /// Follows the Hollywood-style script convention:
    /// - Tab-indented lines = sung/spoken lyrics
    /// - Lines in `[brackets]` even if tab-indented = stage directions (excluded)
    /// - Everything at column 0 = structural (headers, character names, prose, directions)
    ///
    /// Returns the extracted lyrics as a single string with words separated by spaces.
    /// Line breaks between lyrics from the same character block are preserved as spaces.
    /// Blank lines between character blocks insert a newline to maintain phrase structure.
    static func extractLyrics(from librettoText: String) -> String {
        let lines = librettoText.components(separatedBy: .newlines)
        var lyricLines: [String] = []
        var lastWasLyric = false

        for line in lines {
            // Only consider tab-indented lines
            guard line.hasPrefix("\t") else {
                // Non-indented line — if we were in lyrics, mark a phrase break
                if lastWasLyric && line.trimmingCharacters(in: .whitespaces).isEmpty {
                    lyricLines.append("")  // Preserve phrase break
                }
                lastWasLyric = false
                continue
            }

            let content = line.trimmingCharacters(in: .whitespaces)

            // Skip empty indented lines
            guard !content.isEmpty else { continue }

            // Skip tab-indented stage directions: [anything in brackets]
            if content.hasPrefix("[") && content.hasSuffix("]") {
                continue
            }

            // Skip tab-indented curly brace instructions: {anything in braces}
            if content.hasPrefix("{") && content.hasSuffix("}") {
                continue
            }

            // Skip tab-indented parenthetical directions: (stage direction)
            // But NOT syllable count annotations like (8) which are short
            if content.hasPrefix("(") && content.hasSuffix(")") && content.count > 4 {
                continue
            }

            // Skip melisma/continuation markers that might be in the text
            if content == "_" { continue }

            // This is a lyric line — strip any trailing syllable count annotations
            // Pattern: lyric text\t\t(8) → just the lyric text
            var lyricText = content
            if let tabRange = lyricText.range(of: "\t", options: .backwards) {
                let afterTab = lyricText[tabRange.upperBound...]
                if afterTab.hasPrefix("(") && afterTab.hasSuffix(")") {
                    // Looks like a syllable count — strip it
                    lyricText = String(lyricText[..<tabRange.lowerBound])
                        .trimmingCharacters(in: .whitespaces)
                }
            }

            guard !lyricText.isEmpty else { continue }

            // Strip any inline {curly brace instructions} from the lyric line
            lyricText = stripCurlyBraceContent(lyricText)
                .trimmingCharacters(in: .whitespaces)
            guard !lyricText.isEmpty else { continue }

            lyricLines.append(lyricText)
            lastWasLyric = true
        }

        return lyricLines.joined(separator: "\n")
    }

    /// Formats a syllable for display in the lyrics lane.
    /// Appends "-" if this is not the last syllable in a word.
    static func formatForDisplay(_ syllable: String, isLastInWord: Bool) -> String {
        isLastInWord ? syllable : syllable + "-"
    }

    /// Formats a full word's syllables for lane display.
    /// Returns array like ["Hel-", "lo"] or ["a-", "maz-", "ing"].
    static func formatAllForDisplay(_ syllables: [String]) -> [String] {
        syllables.enumerated().map { i, syl in
            formatForDisplay(syl, isLastInWord: i == syllables.count - 1)
        }
    }

    // MARK: - Word Tokenization

    /// Uses NLTokenizer to split text into words, filtering punctuation and whitespace.
    private static func tokenizeWords(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range])
            // Skip pure punctuation / numbers
            if word.rangeOfCharacter(from: .letters) != nil {
                words.append(word)
            }
            return true
        }
        return words
    }

    // MARK: - Exceptions Dictionary

    /// Hand-curated hyphenation exceptions for common words the TeX patterns miss.
    /// Keys are lowercased; values are arrays of syllable break positions (0-indexed
    /// into the character array, indicating where to split before).
    private static let exceptions: [String: [Int]] = [
        // Compound words
        "cannot": [3],           // can-not
        "into": [2],             // in-to
        "onto": [2],             // on-to
        "upon": [2],             // up-on
        "maybe": [3],            // may-be
        "itself": [2],           // it-self
        "myself": [2],           // my-self
        "himself": [3],          // him-self
        "herself": [3],          // her-self
        "yourself": [4],         // your-self
        "someone": [4],          // some-one
        "something": [4],        // some-thing
        "sometimes": [4],        // some-times
        "somewhere": [4],        // some-where
        "anyone": [3],           // any-one
        "anything": [3],         // any-thing
        "anywhere": [3],         // any-where
        "everyone": [5],         // every-one
        "everything": [5],       // every-thing
        "everywhere": [5],       // every-where
        "nobody": [2],           // no-body
        "nothing": [4],          // noth-ing
        "without": [4],          // with-out
        "within": [4],           // with-in
        "outside": [3],          // out-side
        "inside": [2],           // in-side
        "today": [2],            // to-day
        "tonight": [2],          // to-night
        "tomorrow": [2, 5],      // to-mor-row
        "forever": [3],          // for-ever
        "goodbye": [4],          // good-bye
        "sunlight": [3],         // sun-light
        "moonlight": [4],        // moon-light
        "daylight": [3],         // day-light
        "midnight": [3],         // mid-night
        "throughout": [7],       // through-out (break at 7 means before 'o')
        "however": [3],          // how-ever
        "whatever": [4],         // what-ever
        "whenever": [4],         // when-ever
        "wherever": [5],         // wher-ever
        "whoever": [3],          // who-ever

        // Common words TeX patterns often miss
        "understand": [2, 5],    // un-der-stand
        "understanding": [2, 5, 9],  // un-der-stand-ing
        "another": [2],          // an-other
        "because": [2],          // be-cause
        "before": [2],           // be-fore
        "behind": [2],           // be-hind
        "believe": [2],          // be-lieve
        "between": [2],          // be-tween
        "beyond": [2],           // be-yond
        "children": [4],         // chil-dren
        "country": [4],          // coun-try
        "daughter": [4],         // daugh-ter
        "different": [3],        // dif-ferent
        "every": [2],            // ev-ery
        "father": [2],           // fa-ther
        "follow": [3],           // fol-low
        "mother": [4],           // moth-er
        "never": [3],            // nev-er
        "other": [3],            // oth-er
        "people": [3],           // peo-ple
        "remember": [2, 5],      // re-mem-ber
        "river": [3],            // riv-er
        "sister": [3],           // sis-ter
        "spirit": [4],           // spir-it
        "together": [2, 5],      // to-geth-er
        "under": [2],            // un-der
        "water": [2],            // wa-ter
        "wonder": [3],           // won-der
        "woman": [3],            // wom-an
        "women": [3],            // wom-en

        // Musical/opera-specific terms
        "singing": [4],          // sing-ing
        "waiting": [4],          // wait-ing
        "listen": [3],           // lis-ten
        "silence": [2],          // si-lence
        "sacred": [2],           // sa-cred
        "gentle": [3],           // gen-tle
        "soldier": [3],          // sol-dier
        "heaven": [4],           // heav-en
        "prayer": [4],           // pray-er
        "mercy": [3],            // mer-cy
        "darkness": [4],         // dark-ness
        "sorrow": [3],           // sor-row
        "morning": [4],          // morn-ing
        "evening": [3],          // eve-ning
        "longing": [4],          // long-ing
        "watching": [5],         // watch-ing
    ]

    // MARK: - CMU Pronouncing Dictionary

    /// Lazily loaded syllable data from CMU Pronouncing Dictionary (135K words).
    /// Maps lowercased word → (preferred, min, max) syllable counts.
    /// - `preferred`: count from the first (most common) pronunciation
    /// - `min`/`max`: range across ALL alternate pronunciations (e.g. FIRE has 1- and 2-syllable variants)
    /// Syllables are counted as the number of vowel phonemes (ARPABET stress markers 0/1/2).
    /// 1,616 words have elastic ranges where min < max (e.g. "fire" 1-2, "every" 2-3).
    private static let cmuSyllableData: [String: (preferred: Int, min: Int, max: Int)] = {
        guard let url = AppBundle.module.url(forResource: "cmudict", withExtension: "dict"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }

        // First pass: collect all syllable counts per word (including alternates).
        var allCounts: [String: [Int]] = [:]
        allCounts.reserveCapacity(140_000)

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix(";;;") else { continue }

            // Strip trailing comments: "WORD P1 P2 # comment"
            let lineWithoutComment: String
            if let hashIdx = trimmed.firstIndex(of: "#") {
                lineWithoutComment = String(trimmed[..<hashIdx]).trimmingCharacters(in: .whitespaces)
            } else {
                lineWithoutComment = trimmed
            }

            // Split into word and phonemes
            let parts = lineWithoutComment.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }

            var word = String(parts[0]).lowercased()

            // Strip alternate pronunciation suffix: "word(2)", "word(3)", etc.
            if word.hasSuffix(")"), let parenIdx = word.lastIndex(of: "(") {
                word = String(word[..<parenIdx])
            }

            // Only accept words with letters (plus apostrophe/hyphen)
            let isValidWord = word.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
            guard isValidWord, !word.isEmpty else { continue }

            // Count vowel phonemes (those ending in 0, 1, or 2 = stress markers)
            let phonemes = parts[1].split(separator: " ")
            var syllableCount = 0
            for phoneme in phonemes {
                if let last = phoneme.last, last == "0" || last == "1" || last == "2" {
                    syllableCount += 1
                }
            }
            guard syllableCount > 0 else { continue }

            allCounts[word, default: []].append(syllableCount)
        }

        // Second pass: collapse to (preferred, min, max).
        var dict: [String: (preferred: Int, min: Int, max: Int)] = [:]
        dict.reserveCapacity(allCounts.count)
        for (word, counts) in allCounts {
            let preferred = counts[0]  // first pronunciation = most common
            let minCount = counts.min()!
            let maxCount = counts.max()!
            dict[word] = (preferred: preferred, min: minCount, max: maxCount)
        }

        return dict
    }()

    /// Backward-compatible access: returns the preferred (first) CMUDict syllable count.
    private static let cmuSyllableCounts: [String: Int] = {
        var dict: [String: Int] = [:]
        dict.reserveCapacity(cmuSyllableData.count)
        for (word, data) in cmuSyllableData {
            dict[word] = data.preferred
        }
        return dict
    }()

    /// Public access for testing: returns the CMUDict syllable count for a word, or nil.
    static func cmuSyllableCount(for word: String) -> Int? {
        cmuSyllableData[word.lowercased()]?.preferred
    }

    // MARK: - Syllable Elasticity

    /// Hand-curated singing-elastic overrides for common words not covered by CMUDict alternates.
    /// These are words where the schwa or liquid vowel can be absorbed in sung performance.
    /// Values are (min, max) syllable counts; preferred comes from CMUDict/hyphenate().
    private static let singingElasticOverrides: [String: (min: Int, max: Int)] = [
        // Schwa-r words (ER0 can be absorbed into preceding vowel in singing)
        "flower": (1, 2), "power": (1, 2), "tower": (1, 2), "shower": (1, 2),
        "player": (1, 2), "layer": (1, 2), "prayer": (1, 2),
        // -ven/-rit/-en words often compressed in fast singing
        "heaven": (1, 2), "spirit": (1, 2), "evil": (1, 2),
        // -ry/-ly medial schwa compression
        "memory": (2, 3), "history": (2, 3), "mystery": (2, 3), "factory": (2, 3),
        "beautiful": (2, 3), "wonderful": (2, 3), "terrible": (2, 3), "horrible": (2, 3),
        "comfortable": (3, 4), "miserable": (3, 4), "considerable": (4, 5),
        // -ering/-ening words (medial schwa absorption)
        "wandering": (2, 3), "wondering": (2, 3), "gathering": (2, 3),
        "whispering": (2, 3), "glittering": (2, 3), "murmuring": (2, 3),
        "following": (2, 3), "entering": (2, 3),
    ]

    /// Returns the elastic syllable range for a word, combining CMUDict alternates + singing overrides.
    /// Returns nil if the word is not in CMUDict and has no override.
    static func cmuSyllableRange(for word: String) -> SyllableRange? {
        let lower = word.lowercased()

        // Start with CMUDict data.
        if let cmu = cmuSyllableData[lower] {
            var minCount = cmu.min
            var maxCount = cmu.max

            // Extend with singing overrides if applicable.
            if let override = singingElasticOverrides[lower] {
                minCount = Swift.min(minCount, override.min)
                maxCount = Swift.max(maxCount, override.max)
            }

            return SyllableRange(min: minCount, preferred: cmu.preferred, max: maxCount)
        }

        // Not in CMUDict — check singing overrides only.
        if let override = singingElasticOverrides[lower] {
            // Use the override max as preferred (standard pronunciation).
            return SyllableRange(min: override.min, preferred: override.max, max: override.max)
        }

        return nil
    }

    /// Syllabifies text with elastic ranges, returning words that can compress/expand to fit note counts.
    ///
    /// Each returned `ElasticWord` has:
    /// - A preferred syllable count (matches `syllabify()`)
    /// - Min/max range from CMUDict alternates + singing overrides
    /// - Pre-computed syllable variants for each possible count
    ///
    /// Non-elastic words get `range = .fixed(count)` with a single variant.
    static func syllabifyElastic(_ text: String) -> [ElasticWord] {
        var cleaned = DirectionParser.stripDirections(from: text)
        cleaned = stripCurlyBraceContent(cleaned)
        let words = tokenizeWords(cleaned)

        return words.map { word in
            let preferredSyllables = hyphenate(word)
            let preferredCount = preferredSyllables.count
            let lower = word.lowercased()

            // Determine elastic range and build verified variants.
            var variants: [Int: [String]] = [:]
            variants[preferredCount] = preferredSyllables
            var achievableMin = preferredCount
            var achievableMax = preferredCount

            if let cmuRange = cmuSyllableRange(for: lower), cmuRange.isElastic {
                // Try each count in the range — only keep variants that actually achieve it.
                for count in cmuRange.min...cmuRange.max where count != preferredCount {
                    let adjusted: [String]
                    if count > preferredCount {
                        // Expansion: use force-split that doesn't skip trailing vowels.
                        adjusted = forceSplitForSinging(preferredSyllables, target: count)
                    } else {
                        // Compression: merge syllables (always works).
                        adjusted = adjustSyllableCount(preferredSyllables, target: count)
                    }
                    if adjusted.count == count {
                        variants[count] = adjusted
                        achievableMin = Swift.min(achievableMin, count)
                        achievableMax = Swift.max(achievableMax, count)
                    }
                }
            }

            let range = SyllableRange(
                min: achievableMin,
                preferred: preferredCount,
                max: achievableMax
            )

            return ElasticWord(word: word, syllableVariants: variants, range: range)
        }
    }

    // MARK: - TeX Hyphenation Algorithm (Liang)

    /// Hyphenates a single word into syllables.
    ///
    /// Priority order:
    /// 1. CMUDict — if the word is monosyllabic per CMU, return immediately
    /// 2. Hand-curated exceptions dictionary
    /// 3. Contractions
    /// 4. TeX hyphenation patterns + vowel-cluster fallback
    /// 5. CMUDict syllable count validation — adjust TeX result to match CMU count
    /// 6. Inflectional suffix heuristic — catch silent -es/-ed for unknown words
    private static func hyphenate(_ word: String) -> [String] {
        guard word.count >= 4 else { return [word] }

        let lower = word.lowercased()

        // ── CMUDict fast path: monosyllabic words ──
        // This catches "makes", "takes", "comes", "loved", "placed", "changed", etc.
        let cmuCount = cmuSyllableCounts[lower]
        if cmuCount == 1 { return [word] }

        // ── Exceptions dictionary ──
        if let breakPositions = exceptions[lower] {
            let result = applySplits(word: word, positions: breakPositions)
            if let target = cmuCount, result.count != target {
                return adjustSyllableCount(result, target: target)
            }
            return result
        }

        // ── Contractions ──
        if let result = hyphenateContraction(word) {
            return result
        }

        // ── TeX pattern matching ──
        let paddedChars = Array("." + lower + ".")
        let len = paddedChars.count

        var values = [Int](repeating: 0, count: len + 1)
        let trie = Self.patternTrie

        for i in 0..<len {
            var node = trie
            for j in i..<len {
                let ch = paddedChars[j]
                guard let next = node.children[ch] else { break }
                node = next
                for (offset, val) in node.values {
                    let pos = i + offset
                    if pos < values.count {
                        values[pos] = max(values[pos], val)
                    }
                }
            }
        }

        let chars = Array(word)
        var syllables: [String] = []
        var start = 0

        for k in 2..<(len - 2) {
            if values[k] % 2 == 1 {
                let breakPos = k - 1
                if breakPos > start && breakPos < chars.count {
                    syllables.append(String(chars[start..<breakPos]))
                    start = breakPos
                }
            }
        }
        syllables.append(String(chars[start...]))

        // Vowel-cluster fallback if TeX found no breaks
        if syllables.count <= 1 {
            let fallback = vowelClusterSplit(word)
            if fallback.count > 1 { syllables = fallback }
        }

        // ── Basic validation ──
        syllables = validateSyllables(syllables)

        // ── CMUDict count validation ──
        // If CMUDict has a syllable count for this word, adjust our result to match.
        if let target = cmuCount, syllables.count != target {
            syllables = adjustSyllableCount(syllables, target: target)
        }

        // ── Inflectional suffix heuristic for words NOT in CMUDict ──
        // Catches silent -es/-ed in words the dictionary doesn't cover.
        if cmuCount == nil && syllables.count > 1 {
            syllables = mergeInflectionalSuffixes(syllables)
        }

        return syllables
    }

    /// Post-validates syllable splits by merging fragments that are too short or lack vowels.
    private static func validateSyllables(_ syllables: [String]) -> [String] {
        guard syllables.count > 1 else { return syllables }

        var result = syllables

        // Merge any trailing syllable of 1 character (usually silent 'e')
        while result.count > 1 && result.last!.count <= 1 {
            result[result.count - 2] += result.last!
            result.removeLast()
        }

        // Merge any leading syllable of 1 character
        while result.count > 1 && result.first!.count <= 1 {
            result[0] = result[0] + result[1]
            result.remove(at: 1)
        }

        // Merge any interior syllable that has no vowel sounds
        var i = 0
        while i < result.count && result.count > 1 {
            let lower = result[i].lowercased()
            let hasVowel = lower.contains(where: { vowels.contains($0) })
            if !hasVowel {
                if i > 0 {
                    result[i - 1] += result[i]
                    result.remove(at: i)
                } else {
                    result[0] = result[0] + result[1]
                    result.remove(at: 1)
                }
            } else {
                i += 1
            }
        }

        // Final check: if a syllable is only 2 chars ending in 'e' at the end of the word,
        // it's likely a silent-e fragment — merge it back
        if result.count > 1 {
            let last = result.last!.lowercased()
            if last.count == 2 && last.hasSuffix("e") {
                let consonants: Set<Character> = ["b","c","d","f","g","h","j","k","l","m","n","p","q","r","s","t","v","w","x","z"]
                if last.count == 2 && consonants.contains(last.first!) {
                    result[result.count - 2] += result.last!
                    result.removeLast()
                }
            }
        }

        return result
    }

    // MARK: - CMUDict Count Adjustment

    /// Adjusts syllable array to match the target count from CMUDict.
    /// If we have too many: merge the shortest adjacent syllables.
    /// If we have too few: try further splitting at vowel boundaries.
    private static func adjustSyllableCount(_ syllables: [String], target: Int) -> [String] {
        var result = syllables

        // Too many syllables — merge shortest fragments
        while result.count > target && result.count > 1 {
            // Find the shortest syllable
            var minLen = Int.max
            var minIdx = 0
            for (i, syl) in result.enumerated() {
                if syl.count < minLen {
                    minLen = syl.count
                    minIdx = i
                }
            }

            // Merge with adjacent — prefer merging toward the end (silent-e patterns)
            if minIdx == result.count - 1 {
                result[minIdx - 1] += result[minIdx]
                result.removeLast()
            } else if minIdx == 0 {
                result[0] = result[0] + result[1]
                result.remove(at: 1)
            } else {
                // Merge with whichever neighbor is shorter
                let leftLen = result[minIdx - 1].count
                let rightLen = result[minIdx + 1].count
                if leftLen <= rightLen {
                    result[minIdx - 1] += result[minIdx]
                    result.remove(at: minIdx)
                } else {
                    result[minIdx] += result[minIdx + 1]
                    result.remove(at: minIdx + 1)
                }
            }
        }

        // Too few syllables — try vowel cluster splitting on longest syllable
        while result.count < target {
            var maxLen = 0
            var maxIdx = 0
            for (i, syl) in result.enumerated() {
                if syl.count > maxLen {
                    maxLen = syl.count
                    maxIdx = i
                }
            }

            let sub = vowelClusterSplit(result[maxIdx])
            if sub.count > 1 {
                result.replaceSubrange(maxIdx...maxIdx, with: sub)
            } else {
                break  // Can't split further
            }
        }

        return result
    }

    // MARK: - Singing Force-Split

    /// Aggressively splits syllables for singing expansion (ignores silent-e rules).
    ///
    /// Unlike `adjustSyllableCount`, this method can split words like "fire" → ["fi", "re"]
    /// and "ery" → ["er", "y"] because in singing, these vowels ARE pronounced as separate
    /// syllable nuclei.
    private static func forceSplitForSinging(_ syllables: [String], target: Int) -> [String] {
        var result = syllables
        guard target > result.count else { return result }

        while result.count < target {
            // Find the longest syllable to split.
            var maxLen = 0
            var maxIdx = 0
            for (i, syl) in result.enumerated() {
                if syl.count > maxLen {
                    maxLen = syl.count
                    maxIdx = i
                }
            }

            let syl = result[maxIdx]
            guard syl.count >= 2 else { break }

            // Find the best split point: prefer V-C boundary, allowing trailing vowels.
            let chars = Array(syl.lowercased())
            var bestSplit: Int? = nil

            for k in 1..<chars.count {
                let prev = chars[k - 1]
                let curr = chars[k]

                // Split at vowel→consonant boundary (e.g., "fi|re", "ev|ery")
                if vowels.contains(prev) && !vowels.contains(curr) {
                    bestSplit = k
                    break
                }
                // Split at consonant→vowel boundary (e.g., "er|y", "flow|er")
                if !vowels.contains(prev) && vowels.contains(curr) && k > 1 {
                    bestSplit = k
                    break
                }
            }

            guard let split = bestSplit else { break }

            let origChars = Array(syl)
            let left = String(origChars[0..<split])
            let right = String(origChars[split...])
            guard !left.isEmpty && !right.isEmpty else { break }

            result.replaceSubrange(maxIdx...maxIdx, with: [left, right])
        }

        return result
    }

    // MARK: - Inflectional Suffix Heuristic

    /// For words NOT in CMUDict, detect silent inflectional suffixes that were
    /// incorrectly split into their own syllable. Handles:
    /// - "-es" after non-sibilant: "makes" → 1 syl (but "boxes" → 2)
    /// - "-ed" after non-t/d: "loved" → 1 syl (but "wanted" → 2)
    private static func mergeInflectionalSuffixes(_ syllables: [String]) -> [String] {
        guard syllables.count > 1 else { return syllables }
        var result = syllables

        guard let lastSyl = result.last?.lowercased() else { return result }
        let prevSyl = result[result.count - 2].lowercased()

        // "-es" that doesn't form its own syllable:
        // After s, z, x, sh, ch, ge, ce → DOES form a syllable (boxes, wishes)
        // After everything else → does NOT (makes, takes, waves)
        if lastSyl == "es" {
            let sibilantEndings = ["s", "z", "x", "sh", "ch", "ce", "ge", "se", "ze"]
            let isSibilant = sibilantEndings.contains(where: { prevSyl.hasSuffix($0) })
            if !isSibilant {
                result[result.count - 2] += result.last!
                result.removeLast()
            }
        }

        // "-ed" that doesn't form its own syllable:
        // After t, d → DOES form a syllable (wanted, loaded)
        // After everything else → does NOT (loved, placed, changed)
        if lastSyl == "ed" {
            if !prevSyl.hasSuffix("t") && !prevSyl.hasSuffix("d") {
                result[result.count - 2] += result.last!
                result.removeLast()
            }
        }

        return result
    }

    // MARK: - Contraction Handling

    /// Common contraction suffixes that form their own syllable when preceded by a
    /// polysyllabic base (e.g., "wouldn't" → "would-n't", but "can't" stays as one).
    /// The apostrophe variants include both straight `'` and curly `'` (U+2019).
    private static func hyphenateContraction(_ word: String) -> [String]? {
        // Normalize curly apostrophe to straight
        let normalized = word.replacingOccurrences(of: "\u{2019}", with: "'")
        let lower = normalized.lowercased()

        // Find the apostrophe position
        guard let apoIdx = lower.firstIndex(of: "'") else { return nil }

        let basePart = String(normalized[normalized.startIndex..<apoIdx])
        let suffix = String(normalized[apoIdx...])  // includes the apostrophe

        // Don't split very short bases — "I'm", "I'd", "I'll" are single syllable
        guard basePart.count >= 2 else { return [word] }

        // Suffixes that are always part of the same syllable as the last base syllable:
        // 's, 'd, 'm, 're — these don't form their own syllable
        let lowerSuffix = suffix.lowercased()
        let singleSyllableSuffixes = ["'s", "'d", "'m"]
        if singleSyllableSuffixes.contains(lowerSuffix) {
            // Syllabify the base and append the suffix to the last syllable
            let baseSyllables = hyphenateBase(basePart)
            if baseSyllables.isEmpty { return [word] }
            var result = baseSyllables
            // Reconstruct with original casing by using the original word
            let origChars = Array(word)
            let splitPoint = basePart.count
            if splitPoint > 0 && splitPoint <= origChars.count {
                result = applySplits(word: basePart, positions: baseSyllableBreaks(basePart))
                if result.isEmpty { result = [basePart] }
                result[result.count - 1] += String(origChars[splitPoint...])
            }
            return result.count > 0 ? result : nil
        }

        // n't suffix handling for singing/vocal context.
        //
        // Singing-specific monosyllabic contractions (CMUDict says 2 but they're 1 in vocal music):
        //   "aren't" /ɑːrnt/, "weren't" /wɜːrnt/ — the schwa is absorbed by the liquid /r/
        //
        // Genuinely 2-syllable contractions (always 2 in singing):
        //   "isn't", "wasn't", "doesn't", "hasn't", "hadn't", "couldn't", "wouldn't",
        //   "shouldn't", "didn't", "haven't" — the reduced vowel (AH0) is clearly sung
        if lowerSuffix == "'t" || lowerSuffix == "n't" {
            // Singing override: contractions where the n't fuses into a single syllable.
            // These have a rhotic base that absorbs the consonant cluster.
            let singingMonosyllabic: Set<String> = ["aren't", "weren't"]
            if singingMonosyllabic.contains(lower) { return [word] }

            // For n't: the base is everything before "n't"
            let nBase: String
            let nSuffix: String
            if lower.hasSuffix("n't") {
                let endIdx = normalized.index(normalized.endIndex, offsetBy: -3)
                nBase = String(normalized[normalized.startIndex..<endIdx])
                nSuffix = String(normalized[endIdx...])
            } else {
                nBase = basePart
                nSuffix = suffix
            }

            guard nBase.count >= 2 else { return [word] }

            // All remaining n't contractions: base + n't = base syllables + 1.
            // The n't suffix always adds a syllable (the schwa in /ənt/ is always sung).
            // Examples: "isn't" = is + n't = 2, "wouldn't" = would + n't = 2,
            //           "couldn't" = could + n't = 2, "doesn't" = does + n't = 2
            // (The singing-override set above already caught "aren't" and "weren't".)
            let breaks = baseSyllableBreaks(nBase)
            var result = applySplits(word: nBase, positions: breaks)
            if result.isEmpty { result = [nBase] }
            result.append(nSuffix)
            return result
        }

        // 're, 've, 'll — these typically form their own syllable
        if ["'re", "'ve", "'ll"].contains(lowerSuffix) {
            let breaks = baseSyllableBreaks(basePart)
            var result = applySplits(word: basePart, positions: breaks)
            if result.isEmpty { result = [basePart] }
            // Use original casing for the suffix portion
            let origChars = Array(word)
            let splitPoint = basePart.count
            if splitPoint < origChars.count {
                result.append(String(origChars[splitPoint...]))
            } else {
                result.append(suffix)
            }
            return result
        }

        return nil
    }

    /// Gets syllable break positions for a word without contraction handling (avoids recursion).
    private static func baseSyllableBreaks(_ word: String) -> [Int] {
        let lower = word.lowercased()
        if let breakPositions = exceptions[lower] {
            return breakPositions
        }
        // Run TeX patterns on the base
        let paddedChars = Array("." + lower + ".")
        let len = paddedChars.count
        var values = [Int](repeating: 0, count: len + 1)
        let trie = Self.patternTrie
        for i in 0..<len {
            var node = trie
            for j in i..<len {
                let ch = paddedChars[j]
                guard let next = node.children[ch] else { break }
                node = next
                for (offset, val) in node.values {
                    let pos = i + offset
                    if pos < values.count {
                        values[pos] = max(values[pos], val)
                    }
                }
            }
        }
        var breaks: [Int] = []
        for k in 2..<(len - 2) {
            if values[k] % 2 == 1 {
                let breakPos = k - 1
                if breakPos > 0 && breakPos < word.count {
                    breaks.append(breakPos)
                }
            }
        }
        return breaks
    }

    /// Syllabifies a base word (no contraction) using TeX patterns or vowel fallback.
    private static func hyphenateBase(_ word: String) -> [String] {
        guard word.count >= 2 else { return [word] }
        let breaks = baseSyllableBreaks(word)
        if !breaks.isEmpty {
            return applySplits(word: word, positions: breaks)
        }
        let fallback = vowelClusterSplit(word)
        return fallback.count > 1 ? fallback : [word]
    }

    // MARK: - Exception Splits Helper

    /// Splits a word at the given character positions, preserving original casing.
    private static func applySplits(word: String, positions: [Int]) -> [String] {
        let chars = Array(word)
        var syllables: [String] = []
        var start = 0
        for pos in positions.sorted() where pos > start && pos < chars.count {
            syllables.append(String(chars[start..<pos]))
            start = pos
        }
        syllables.append(String(chars[start...]))
        return syllables
    }

    // MARK: - Vowel Cluster Fallback

    private static let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]

    /// Enhanced vowel-cluster heuristic. Handles:
    /// - V-C-V: break before the consonant (ba-ker)
    /// - V-CC-V: break between the consonants (can-not, sis-ter)
    /// - V-CCC-V: break after first consonant (mon-ster)
    /// Less accurate than TeX patterns but handles unknown words and names.
    private static func vowelClusterSplit(_ word: String) -> [String] {
        let chars = Array(word.lowercased())
        let origChars = Array(word)
        guard chars.count >= 4 else { return [word] }

        var breaks: [Int] = []
        var i = 1
        while i < chars.count - 1 {
            let prev = chars[i - 1]
            let curr = chars[i]

            if vowels.contains(prev) && !vowels.contains(curr) {
                // Found V-C... count the consonant cluster length
                var clusterEnd = i
                while clusterEnd < chars.count && !vowels.contains(chars[clusterEnd]) {
                    clusterEnd += 1
                }
                let clusterLen = clusterEnd - i

                // Only break if there's a vowel after the cluster
                if clusterEnd < chars.count && vowels.contains(chars[clusterEnd]) {
                    // Don't break if the vowel after the cluster is a trailing silent-e
                    // (last char of the word and it's 'e'). This prevents "love" → "lo-ve",
                    // "time" → "ti-me", "home" → "ho-me", etc.
                    let isTrailingSilentE = clusterEnd == chars.count - 1
                        && chars[clusterEnd] == Character("e")

                    if !isTrailingSilentE {
                        if clusterLen == 1 {
                            // V-C-V: break before the consonant (ba-ker)
                            breaks.append(i)
                        } else if clusterLen == 2 {
                            // V-CC-V: break between the consonants (can-not, sis-ter)
                            breaks.append(i + 1)
                        } else if clusterLen >= 3 {
                            // V-CCC-V: break after first consonant (mon-ster, chil-dren)
                            breaks.append(i + 1)
                        }
                    }
                    i = clusterEnd + 1 // Skip past the vowel after the cluster
                } else {
                    i += 1
                }
            } else {
                i += 1
            }
        }

        guard !breaks.isEmpty else { return [word] }

        var syllables: [String] = []
        var start = 0
        for bp in breaks {
            syllables.append(String(origChars[start..<bp]))
            start = bp
        }
        syllables.append(String(origChars[start...]))
        return syllables
    }

    // MARK: - Pattern Trie

    /// Trie node for TeX hyphenation patterns.
    private final class TrieNode {
        var children: [Character: TrieNode] = [:]
        /// (offset, value) pairs — offset is relative to the start of the matched substring.
        var values: [(offset: Int, value: Int)] = []
    }

    /// Lazily loaded pattern trie from the bundled resource file.
    /// Safe: write-once at first access, read-only thereafter.
    nonisolated(unsafe) private static let patternTrie: TrieNode = {
        let root = TrieNode()

        guard let url = AppBundle.module.url(forResource: "hyph-en-us.pat", withExtension: "txt"),
              let content = try? String(contentsOf: url, encoding: .utf8) else {
            // Fallback: return empty trie — vowel-cluster will handle all words
            return root
        }

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("%"), !trimmed.hasPrefix("#") else { continue }
            insertPattern(trimmed, into: root)
        }

        return root
    }()

    /// Parses a single TeX pattern string like "ab2c1d" into trie nodes.
    /// Letters are trie keys; digits are hyphenation values at their positions.
    private static func insertPattern(_ pattern: String, into root: TrieNode) {
        var chars: [Character] = []
        var digitPositions: [(offset: Int, value: Int)] = []

        for ch in pattern {
            if ch.isNumber, let val = ch.wholeNumberValue {
                digitPositions.append((offset: chars.count, value: val))
            } else {
                chars.append(ch)
            }
        }

        guard !chars.isEmpty else { return }

        // Walk trie, creating nodes as needed
        var node = root
        for ch in chars {
            if node.children[ch] == nil {
                node.children[ch] = TrieNode()
            }
            node = node.children[ch]!
        }
        node.values = digitPositions
    }
}
