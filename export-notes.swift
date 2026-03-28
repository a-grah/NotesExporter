// export-notes.swift — Export selected notes from Apple Notes.app via Scripting Bridge
// Build: make
// Usage: ./export-notes [-f format] [-o outdir] [-a account] [-F folder] [-r regex]
//
// Formats: md (default), html, txt, pdf
// Notes.h / BridgingHeader.h are kept for IDE reference; not needed for compilation.

import Foundation
import ScriptingBridge

// MARK: - Helpers

func pad(_ s: String, _ width: Int) -> String {
    let t = s.count > width ? String(s.prefix(width)) : s
    return t + String(repeating: " ", count: max(0, width - t.count))
}

func printErr(_ msg: String) { fputs(msg + "\n", stderr) }

// MARK: - Pre-compiled HTML→Markdown regex patterns
//
// Compiled once at startup; reused for every note instead of rebuilding
// NSRegularExpression objects on each htmlToMarkdown() call.

let mdRegexes: [(NSRegularExpression, String)] = [
    (#"<br[^>]*>"#,     "\n"),
    (#"</p>"#,          "\n\n"),
    (#"</h[123]>"#,     "\n\n"),
    (#"<h1[^>]*>"#,     "# "),
    (#"<h2[^>]*>"#,     "## "),
    (#"<h3[^>]*>"#,     "### "),
    (#"</li>"#,         "\n"),
    (#"<li[^>]*>"#,     "- "),
    (#"<strong[^>]*>"#, "**"),
    (#"</strong>"#,     "**"),
    (#"<em[^>]*>"#,     "*"),
    (#"</em>"#,         "*"),
    (#"<[^>]*>"#,       ""),
    (#"\n{3,}"#,        "\n\n"),
].compactMap { (pattern, replacement) -> (NSRegularExpression, String)? in
    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
    return (re, replacement)
}

// MARK: - Config & argument parsing

struct Config {
    var format = "md"
    var outDir = "./exported-notes"
    var account = ""
    var folder  = ""
    var regex   = ""
}

func printUsage() {
    print("""
    Usage: export-notes [options]

    Options:
      -f FORMAT   Output format: md, html, txt, pdf (default: md)
      -o DIR      Output directory (default: ./exported-notes)
      -a ACCOUNT  Filter by account name (e.g. "iCloud")
      -F FOLDER   Filter by folder name
      -r REGEX    Export notes whose title matches this regex (skips interactive selection)
      -v          Show version and exit
      -h          Show this help
    """)
}

var cfg = Config()
let argv = Array(CommandLine.arguments.dropFirst())
var ai = 0
while ai < argv.count {
    let flag = argv[ai]
    func next(_ f: String) -> String {
        ai += 1
        guard ai < argv.count else { printErr("Error: \(f) requires a value"); exit(1) }
        return argv[ai]
    }
    switch flag {
    case "-f": cfg.format  = next("-f")
    case "-o": cfg.outDir  = next("-o")
    case "-a": cfg.account = next("-a")
    case "-F": cfg.folder  = next("-F")
    case "-r": cfg.regex   = next("-r")
    case "-v", "--version": print("export-notes \(appVersion)"); exit(0)
    case "-h", "--help": printUsage(); exit(0)
    default:
        printErr("Unknown option: \(flag)")
        printUsage()
        exit(1)
    }
    ai += 1
}

guard ["md", "html", "txt", "pdf"].contains(cfg.format) else {
    printErr("Error: format must be md, html, txt, or pdf")
    exit(1)
}

if cfg.format == "pdf" {
    let check = Process()
    check.launchPath = "/usr/bin/which"
    check.arguments  = ["wkhtmltopdf"]
    check.standardOutput = FileHandle.nullDevice
    check.standardError  = FileHandle.nullDevice
    check.launch(); check.waitUntilExit()
    guard check.terminationStatus == 0 else {
        printErr("Error: 'wkhtmltopdf' is required for PDF export but was not found.")
        printErr("Install it with: brew install wkhtmltopdf")
        exit(1)
    }
}

// MARK: - Connect to Notes.app

guard let app = SBApplication(bundleIdentifier: "com.apple.Notes") else {
    printErr("Error: Could not connect to Notes.app")
    exit(1)
}

print("Reading notes from Notes.app...")

// MARK: - Step 1: Fetch note list
//
// SBElementArray.value(forKey:) sends one Apple Event for the entire folder,
// so listing costs 3 events per folder regardless of how many notes it holds.

struct NoteInfo {
    let account: String
    let folder:  String
    let name:    String
    let modDate: Date
    let id:      String
    let ref:     SBObject   // proxy — no Apple Event until a property is read
}

let isoFmt = ISO8601DateFormatter()
var allNotes: [NoteInfo] = []

let accounts = app.value(forKey: "accounts") as? NSArray ?? []
for acctObj in accounts {
    let acct = acctObj as AnyObject
    let acctName = acct.value(forKey: "name") as? String ?? ""
    let folders = acct.value(forKey: "folders") as? NSArray ?? []
    for folderObj in folders {
        let folder = folderObj as AnyObject
        let folderName = folder.value(forKey: "name") as? String ?? ""
        guard let notesArr = folder.value(forKey: "notes") as? SBElementArray else { continue }

        // 3 Apple Events for the whole folder — one per property
        let names = notesArr.value(forKey: "name") as? [String] ?? []
        let dates = notesArr.value(forKey: "modificationDate") as? [Date] ?? []
        let ids   = notesArr.value(forKey: "id") as? [String] ?? []

        for i in 0..<names.count {
            guard let ref = notesArr.object(at: i) as? SBObject else { continue }
            allNotes.append(NoteInfo(
                account: acctName,
                folder:  folderName,
                name:    names[i],
                modDate: i < dates.count ? dates[i] : Date(),
                id:      i < ids.count  ? ids[i]   : "",
                ref:     ref
            ))
        }
    }
}

if allNotes.isEmpty {
    print("No notes found.")
    exit(0)
}

// MARK: - Step 2: Filter

let filtered: [NoteInfo] = allNotes.filter { note in
    if !cfg.account.isEmpty, note.account != cfg.account { return false }
    if !cfg.folder.isEmpty,  note.folder  != cfg.folder  { return false }
    if !cfg.regex.isEmpty {
        guard note.name.range(of: cfg.regex, options: .regularExpression) != nil else { return false }
    }
    return true
}

if filtered.isEmpty {
    print("No notes match the given filters.")
    exit(0)
}

// MARK: - Step 3: Display & select

print("")
print("\(pad("#", 5))  \(pad("ACCOUNT", 15))  \(pad("FOLDER", 20))  \(pad("MODIFIED", 12))  TITLE")
print("\(pad("---", 5))  \(pad("---------------", 15))  \(pad("--------------------", 20))  \(pad("------------", 12))  -----")

for (i, note) in filtered.enumerated() {
    let dateStr = String(isoFmt.string(from: note.modDate).prefix(10))
    print("\(pad(String(i + 1), 5))  \(pad(note.account, 15))  \(pad(note.folder, 20))  \(pad(dateStr, 12))  \(note.name)")
}

var selectedIndices: [Int]

if !cfg.regex.isEmpty {
    selectedIndices = Array(filtered.indices)
} else {
    print("")
    print("Found \(filtered.count) note(s). Enter selection:")
    print("  - Individual numbers: 1 3 5")
    print("  - Ranges: 2-7")
    print("  - All: a")
    print("  - Quit: q")
    print("")
    print("Selection: ", terminator: "")
    fflush(stdout)

    guard let line = readLine()?.trimmingCharacters(in: .whitespaces), !line.isEmpty else {
        print("Nothing selected."); exit(0)
    }
    if line == "q" { print("Cancelled."); exit(0) }

    var indices: [Int] = []
    if line.lowercased() == "a" {
        indices = Array(filtered.indices)
    } else {
        let rangeRE = try! NSRegularExpression(pattern: #"^(\d+)-(\d+)$"#)
        for token in line.split(separator: " ").map(String.init) {
            if rangeRE.firstMatch(in: token, range: NSRange(token.startIndex..., in: token)) != nil {
                let parts = token.split(separator: "-").compactMap { Int($0) }
                if parts.count == 2 {
                    let lo = min(parts[0], parts[1]) - 1
                    let hi = max(parts[0], parts[1]) - 1
                    for j in lo...hi where j >= 0 && j < filtered.count { indices.append(j) }
                }
            } else if let n = Int(token) {
                let idx = n - 1
                if idx >= 0 && idx < filtered.count {
                    indices.append(idx)
                } else {
                    printErr("Warning: #\(n) out of range, skipping.")
                }
            } else {
                printErr("Warning: unrecognised token '\(token)', skipping.")
            }
        }
    }
    selectedIndices = indices
}

if selectedIndices.isEmpty { print("Nothing selected."); exit(0) }

// MARK: - Step 4: Export

let fm = FileManager.default
try? fm.createDirectory(atPath: cfg.outDir, withIntermediateDirectories: true, attributes: nil)

let (fileExt, contentKey): (String, String) = {
    switch cfg.format {
    case "txt":  return ("txt",  "plaintext")
    case "html": return ("html", "body")
    case "pdf":  return ("pdf",  "body")
    default:     return ("md",   "body")
    }
}()

print("")
print("Exporting \(selectedIndices.count) note(s) as \(cfg.format) to \(cfg.outDir)/ ...")

// MARK: - Helpers

func htmlToMarkdown(_ html: String) -> String {
    var s = html
    for (re, replacement) in mdRegexes {
        s = re.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func sanitize(_ name: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
    var s = name.unicodeScalars.map { forbidden.contains($0) ? "_" : String($0) }.joined()
    while s.hasPrefix(".") { s = String(s.dropFirst()) }
    s = String(s.prefix(200))
    return s.isEmpty ? "untitled" : s
}

var allocatedPaths = Set<String>()

func uniquePath(dir: String, name: String, ext: String) -> String {
    func taken(_ p: String) -> Bool { fm.fileExists(atPath: p) || allocatedPaths.contains(p) }
    let base = "\(dir)/\(name).\(ext)"
    if !taken(base) { allocatedPaths.insert(base); return base }
    var n = 2
    while taken("\(dir)/\(name)_\(n).\(ext)") { n += 1 }
    let path = "\(dir)/\(name)_\(n).\(ext)"
    allocatedPaths.insert(path)
    return path
}

// MARK: - Fetch content
//
// Bulk mode (> 20 notes): 2 Apple Events total — one for all IDs, one for all
// bodies — regardless of selection size. Fetches every note's content, but the
// single round-trip is far faster than N serial Apple Events for large exports.
//
// Per-note mode (≤ 20 notes): 1 Apple Event per selected note. Avoids pulling
// bodies for notes the user didn't ask for.

let bulkThreshold = 20
var contentMap: [String: String] = [:]

if selectedIndices.count > bulkThreshold {
    let appNotes    = app.value(forKey: "notes") as! SBElementArray
    let allIds      = appNotes.value(forKey: "id")       as? [String] ?? []
    let allContents = appNotes.value(forKey: contentKey) as? [String] ?? []
    for (i, id) in allIds.enumerated() {
        contentMap[id] = i < allContents.count ? allContents[i] : ""
    }
} else {
    for idx in selectedIndices {
        let note = filtered[idx]
        contentMap[note.id] = note.ref.value(forKey: contentKey) as? String ?? ""
    }
}

// MARK: - Build write tasks
//
// Paths are resolved serially to guarantee uniquePath's collision detection
// is race-free. Content processing (HTML→Markdown) also happens here so the
// concurrent write phase only does I/O.

struct WriteTask {
    let noteName: String
    let content:  String
    let outPath:  String
}

let pid = ProcessInfo.processInfo.processIdentifier
var tasks: [WriteTask] = []
tasks.reserveCapacity(selectedIndices.count)

for (i, idx) in selectedIndices.enumerated() {
    let note = filtered[idx]
    var content = contentMap[note.id] ?? ""
    if cfg.format == "md" { content = htmlToMarkdown(content) }
    let outPath = uniquePath(dir: cfg.outDir, name: sanitize(note.name), ext: fileExt)
    tasks.append(WriteTask(noteName: note.name, content: content, outPath: outPath))

    if cfg.format == "pdf" {
        // For PDF, temp file name needs a stable index; precompute it here.
        _ = i  // index available as `i` inside the PDF block below
    }
}

// MARK: - Write files (concurrent)
//
// Each task is independent: different output paths, no shared mutable state.
// Messages are collected by index so output order matches selection order.

var messages = [String](repeating: "", count: tasks.count)

DispatchQueue.concurrentPerform(iterations: tasks.count) { i in
    let task = tasks[i]

    if cfg.format == "pdf" {
        let tmpHtml = NSTemporaryDirectory() + "note_\(pid)_\(i).html"
        try? task.content.write(toFile: tmpHtml, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments  = ["wkhtmltopdf", "--quiet", tmpHtml, task.outPath]
        proc.launch(); proc.waitUntilExit()
        try? fm.removeItem(atPath: tmpHtml)
    } else {
        try? task.content.write(toFile: task.outPath, atomically: true, encoding: .utf8)
    }

    messages[i] = "  ✓ \(task.noteName) → \((task.outPath as NSString).lastPathComponent)"
}

for msg in messages { print(msg) }

print("")
print("Done. Files saved to \(cfg.outDir)/")
