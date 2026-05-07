import Foundation

public enum CLIPTokenizerError: Error, CustomStringConvertible {
    case vocabFileNotFound
    case vocabParseFailed(String)
    case unknownToken(String)

    public var description: String {
        switch self {
        case .vocabFileNotFound:
            return """
            CLIP tokenizer vocab not found. Run scripts/convert_openclip.py — it \
            writes Resources/Tokenizer/clip-bpe-merges.txt alongside the encoder \
            mlpackages.
            """
        case .vocabParseFailed(let detail): return "Vocab parse failed: \(detail)"
        case .unknownToken(let t): return "BPE produced sub-token not in vocab: \(t)"
        }
    }
}

/// Byte-level BPE tokenizer matching openai/CLIP's `simple_tokenizer.py`.
///
/// Algorithm:
///   1. Lowercase + whitespace-clean input
///   2. Split via Unicode-aware regex (letters / digits / punctuation runs)
///   3. For each token:
///      a. UTF-8 encode → bytes
///      b. Map each byte through `byteEncoder` to a unique unicode char
///      c. Apply BPE merges greedily by rank until no more apply
///   4. Look up each merged subword in the vocab → integer ID
///   5. Prepend SOS (49406), append EOS (49407), pad with 0 to context length 77
///
/// The vocab file ships alongside the converted OpenCLIP encoder. Currently
/// uses an uncompressed plain-text format — each non-blank line after the
/// initial `#version` header is a BPE merge ("a b" = merge token "a"+"b"
/// when adjacent).
public final class CLIPBPETokenizer: Sendable {
    public static let contextLength = 77
    /// Expected SOS for the standard CLIP vocab (49,408 tokens). Tokenizers
    /// constructed from non-standard merges files have a different value
    /// available via `startTokenID`.
    public static let standardStartToken: Int32 = 49406
    public static let standardEndToken: Int32 = 49407
    public static let padToken: Int32 = 0

    public let startTokenID: Int32
    public let endTokenID: Int32
    public let vocabSize: Int

    private let byteEncoder: [UInt8: String]
    private let bpeRanks: [Pair: Int]
    private let encoder: [String: Int32]
    private let pattern: NSRegularExpression

    private struct Pair: Hashable, Sendable {
        let first: String
        let second: String
    }

    /// Load tokenizer from a merges file. The file format matches what
    /// `convert_openclip.py` produces:
    ///   - First non-blank line: `#version: 0.2` (header, ignored)
    ///   - Subsequent lines: `a b` (one merge per line)
    ///   - Lines beyond ~48,894 are ignored (cap matches openai/CLIP)
    public init(mergesFileURL: URL) throws {
        guard let text = try? String(contentsOf: mergesFileURL, encoding: .utf8) else {
            throw CLIPTokenizerError.vocabFileNotFound
        }

        // Build byte → unicode-char encoder identical to bytes_to_unicode() in Python.
        let localByteEncoder = Self.makeByteEncoder()
        self.byteEncoder = localByteEncoder

        // Parse merges, capped at openai/CLIP's count (49152 - 256*2 - 2 = 48894).
        let mergeLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .lazy
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .prefix(48894)

        var ranks: [Pair: Int] = [:]
        var merges: [Pair] = []
        for (i, line) in mergeLines.enumerated() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else {
                throw CLIPTokenizerError.vocabParseFailed("line \(i + 2): expected 'a b', got '\(line)'")
            }
            let pair = Pair(first: parts[0], second: parts[1])
            ranks[pair] = i
            merges.append(pair)
        }
        self.bpeRanks = ranks

        // Build the encoder vocab in the canonical order:
        //   1. Byte chars (256)
        //   2. Byte chars + "</w>" (256)
        //   3. Merged tokens (in merge order)
        //   4. <|startoftext|>, <|endoftext|>
        var vocab: [String] = []
        let byteChars = (0..<256).map { localByteEncoder[UInt8($0)]! }
        vocab.append(contentsOf: byteChars)
        vocab.append(contentsOf: byteChars.map { $0 + "</w>" })
        for merge in merges {
            vocab.append(merge.first + merge.second)
        }
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        var encoderDict: [String: Int32] = [:]
        encoderDict.reserveCapacity(vocab.count)
        for (i, token) in vocab.enumerated() {
            encoderDict[token] = Int32(i)
        }
        self.encoder = encoderDict
        self.vocabSize = vocab.count
        // SOS/EOS are appended last to the vocab. For the standard CLIP
        // merges file these match `standardStartToken` (49406) / `standardEndToken`
        // (49407); test tokenizers built from synthetic merges files have
        // smaller vocabs but still derive these the same way.
        self.startTokenID = encoderDict["<|startoftext|>"]!
        self.endTokenID = encoderDict["<|endoftext|>"]!

        // Tokenization regex: special tokens, contractions, runs of letters,
        // single digits, runs of non-whitespace non-letter non-digit chars.
        // Mirrors openai/CLIP's pattern; \p{L}/\p{N} require Unicode-aware engine.
        let regexPattern = #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
        self.pattern = try NSRegularExpression(
            pattern: regexPattern,
            options: [.caseInsensitive]
        )
    }

    /// Tokenize input text into a fixed-length array of `contextLength` ints.
    /// SOS is at position 0; EOS follows the last real token; remaining slots
    /// are filled with `padToken`.
    public func encode(_ text: String) throws -> [Int32] {
        let cleaned = Self.whitespaceClean(text).lowercased()

        // Apply regex tokenization.
        let nsText = cleaned as NSString
        let matches = pattern.matches(in: cleaned, range: NSRange(location: 0, length: nsText.length))

        var tokenIDs: [Int32] = [startTokenID]

        for match in matches {
            let token = nsText.substring(with: match.range)
            // Byte-encode then BPE-merge.
            let bytes = Array(token.utf8)
            let byteEncoded = bytes.map { byteEncoder[$0]! }.joined()
            let merged = bpeMerge(byteEncoded)
            for subToken in merged.split(separator: " ").map(String.init) {
                guard let id = encoder[subToken] else {
                    throw CLIPTokenizerError.unknownToken(subToken)
                }
                tokenIDs.append(id)
                if tokenIDs.count >= Self.contextLength - 1 { break }
            }
            if tokenIDs.count >= Self.contextLength - 1 { break }
        }

        tokenIDs.append(endTokenID)
        // Pad to context length.
        while tokenIDs.count < Self.contextLength {
            tokenIDs.append(Self.padToken)
        }
        return tokenIDs
    }

    // MARK: - BPE merge

    /// Apply BPE merges to a single byte-encoded word. The input is a string
    /// of unicode chars from `byteEncoder`; treat each char as a "symbol" and
    /// repeatedly merge the highest-priority adjacent pair.
    private func bpeMerge(_ token: String) -> String {
        guard token.count > 1 else { return token + "</w>" }

        // Initial symbols: each char of token, with last char + "</w>".
        var symbols = token.map { String($0) }
        if let last = symbols.last {
            symbols[symbols.count - 1] = last + "</w>"
        }

        while symbols.count > 1 {
            // Find adjacent pair with lowest rank (= highest priority).
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                let pair = Pair(first: symbols[i], second: symbols[i + 1])
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            if bestIndex < 0 { break }  // no more applicable merges

            // Merge ALL non-overlapping occurrences of the chosen pair.
            let first = symbols[bestIndex]
            let second = symbols[bestIndex + 1]
            var merged: [String] = []
            var i = 0
            while i < symbols.count {
                if i < symbols.count - 1 && symbols[i] == first && symbols[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(symbols[i])
                    i += 1
                }
            }
            symbols = merged
        }

        return symbols.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Whitespace clean: collapse runs of whitespace to single space, trim ends.
    private static func whitespaceClean(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Build the byte → unicode-char encoding identical to GPT-2's
    /// `bytes_to_unicode()`. Printable bytes map to themselves; other bytes
    /// map to chars in the U+0100–U+01FF range so every byte gets a unique,
    /// non-control, non-whitespace unicode representation.
    private static func makeByteEncoder() -> [UInt8: String] {
        var bs: [Int] = []
        bs.append(contentsOf: Int(Character("!").asciiValue!)...Int(Character("~").asciiValue!))
        bs.append(contentsOf: 0xA1...0xAC)
        bs.append(contentsOf: 0xAE...0xFF)

        var cs = bs
        var n = 0
        for b in 0..<256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }

        var encoder: [UInt8: String] = [:]
        for (byte, code) in zip(bs, cs) {
            encoder[UInt8(byte)] = String(UnicodeScalar(code)!)
        }
        return encoder
    }

    // MARK: - Discovery

    /// Try to find the merges file in standard locations: `PV_TOKENIZER_DIR`
    /// override, repo `Resources/Tokenizer/`, app bundle, then user data.
    public static func locateMergesFile() -> URL? {
        let fileName = "clip-bpe-merges.txt"
        for dir in searchDirectories() {
            let candidate = dir.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func searchDirectories() -> [URL] {
        var dirs: [URL] = []
        if let envPath = ProcessInfo.processInfo.environment["PV_TOKENIZER_DIR"] {
            dirs.append(URL(fileURLWithPath: envPath, isDirectory: true))
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoTokenizer = thisFile
            .deletingLastPathComponent()  // Sources/PhotoSearch
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Resources/Tokenizer", isDirectory: true)
        dirs.append(repoTokenizer)
        if let bundleResources = Bundle.main.resourceURL {
            dirs.append(bundleResources.appendingPathComponent("Tokenizer", isDirectory: true))
        }
        return dirs
    }
}
