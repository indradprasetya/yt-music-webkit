#!/usr/bin/env python3
"""Check native translation batching, preferences, cancellation and installed language models."""
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
checks = r'''
import AppKit
import Translation

@MainActor func call(_ service: MusicLyricsTranslation, _ body: [String: Any]) async throws -> [String: Any] {
    try await withCheckedThrowingContinuation { continuation in
        service.handle(body) { value, error in
            if let error { continuation.resume(throwing: NSError(domain: "TranslationCheck", code: 1,
                userInfo: [NSLocalizedDescriptionKey: error])) }
            else { continuation.resume(returning: value as! [String: Any]) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
setbuf(stdout, nil)
Task { @MainActor in
    do {
        let english = ["The sky is clear today.", "We can walk beside the river.", "Come closer", "Stay", "Oh oh", "La la", "Good morning", "Together", "Go on", "Where are you?", "I will wait for the rain to stop."]
        let batches = MusicLyricsTranslation.batches(english, target: "id")
        precondition(batches.count == 1 && batches[0].source == "en" && batches[0].indices == Array(0..<11),
            "Short English lines must not trigger Indonesian/Spanish models")
        precondition(MusicLyricsTranslation.batches(english, target: "en").isEmpty,
            "Do not request translation into the source language")
        let korean = MusicLyricsTranslation.batches(["함께 걸어요", "오늘은 좋은 날입니다"], target: "id")
        precondition(korean.count == 1 && korean[0].source == "ko")
        let japanese = MusicLyricsTranslation.batches(["明日は晴れる", "こんにちは世界"], target: "id")
        precondition(japanese.count == 1 && japanese[0].source == "ja")
        let mandarin = MusicLyricsTranslation.batches(["今天我们一起看星星", "你好世界"], target: "id")
        precondition(mandarin.count == 1 && mandarin[0].source == "zh-Hans")
        let large = MusicLyricsTranslation.batches(Array(repeating: "The sky is clear today.", count: 35), target: "id")
        precondition(large.map { $0.indices.count } == [16, 16, 3])
        let suite = "TranslationCheck-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MusicLyricsTranslation(defaults: defaults)
        let options = try await call(service, ["action": "options"])
        let languages = options["languages"] as! [[String: String]]
        guard let target = languages.first(where: { Locale.Language(identifier: $0["code"]!).languageCode?.identifier == "id" })?["code"] else {
            fatalError("Indonesian must be available on the test Mac")
        }
        precondition(service.preferences["translate"] == nil && service.preferences["pronunciation"] == nil, "The translation engine must not own display preferences")
        _ = try await call(service, ["action": "preferences", "target": target])
        precondition(MusicLyricsTranslation(defaults: defaults).preferences["target"] as? String == target)
        do { _ = try await call(service, ["action": "translate", "target": "", "texts": ["Text"]]); fatalError("Reject invalid targets") } catch {}
        do { _ = try await call(service, ["action": "translate", "target": target, "texts": [" "]]); fatalError("Reject blank lines") } catch {}
        var replies: [[String: Any]] = []
        var phases: [String] = []
        service.handle(["action": "translate", "target": target, "texts": english], onStatus: { phases.append($0) }) { value, _ in replies.append(value as! [String: Any]) }
        service.cancel()
        precondition(replies.count == 1 && replies[0]["status"] as? String == "cancelled")
        try await Task.sleep(for: .milliseconds(30))
        precondition(replies.count == 1 && phases == ["checking"], "A cancelled request must reply exactly once without stale progress")
        let romanized = try await call(service, ["action": "pronunciation", "texts": ["夜だ", "你好", "안녕", "夜だ"],
            "pronunciations": ["yoru da", "nǐ hǎo", "annyeong", "unrelated reading"],
            "words": [
                [["word": "夜", "start_time": 1000, "end_time": 2000], ["word": "だ", "start_time": 2000, "end_time": 3000]],
                [["word": "你", "start_time": 1000, "end_time": 2000], ["word": "好", "start_time": 2000, "end_time": 3000]],
                [["word": "안", "start_time": 1000, "end_time": 2000], ["word": "녕", "start_time": 2000, "end_time": 3000]],
                [["word": "夜", "start_time": 1000, "end_time": 2000], ["word": "だ", "start_time": 2000, "end_time": 3000]]
            ]])
        guard let phoneticLines = romanized["lines"] as? [[String: Any]], phoneticLines.count == 4 else {
            fatalError("Pronunciation must return text plus independently timed words")
        }
        for line in phoneticLines.prefix(3) {
            let words = line["words"] as? [[String: Any]]
            precondition(words?.count == 2 && words?.first?["start_time"] as? Int == 1000 && words?.last?["end_time"] as? Int == 3000)
            precondition(words?.compactMap { $0["word"] as? String }.joined() == line["text"] as? String, "Preserve exact pronunciation display text")
        }
        precondition((phoneticLines[3]["words"] as? [[String: Any]])?.isEmpty == true && phoneticLines[3]["text"] as? String == "unrelated reading", "Mismatched provider readings must remain line-level")
        print("PASS: native language context, per-song-compatible preferences, cancellation and conservative CJK pronunciation timing")
        if CommandLine.arguments.contains("--live") {
            let availability: LanguageAvailability
            if #available(macOS 26.4, *) { availability = LanguageAvailability(preferredStrategy: .lowLatency) }
            else { availability = LanguageAvailability() }
            let installed = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: target))
            if #available(macOS 26.0, *), installed == .installed {
                let repeated = Array(repeating: english, count: 5).flatMap { $0 }
                let start = Date()
                let result = try await call(service, ["action": "translate", "target": target, "texts": repeated])
                guard let lines = result["texts"] as? [String], lines.count == 55,
                      !lines[0].isEmpty, !lines[1].isEmpty, result["message"] as? String == "" else {
                    fatalError("Native lyric translation did not complete: \(result)")
                }
                precondition(lines[0] == lines[11] && lines[1] == lines[12], "Keep repeated lines aligned")
                print("PASS: installed native English → Indonesian, 55 lyric lines, seconds:", Date().timeIntervalSince(start))
                let cached = try await call(service, ["action": "translate", "target": target, "texts": repeated])
                precondition(cached["texts"] as? [String] == lines, "Restore complete cached translations")
            } else { print("SKIP: live native check requires macOS 26+ and installed English/Indonesian models") }
        }
        exit(0)
    } catch { print("FAIL:", error.localizedDescription); exit(1) }
}
app.run()
'''
with tempfile.TemporaryDirectory(prefix="music-translation-check-") as directory:
    work = Path(directory)
    (work / "main.swift").write_text(checks)
    binary = work / "check"
    subprocess.run(["xcrun", "swiftc", str(root / "Music/MusicLyricsTranslation.swift"),
                    str(work / "main.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary), *sys.argv[1:]], check=True, timeout=75)
