// export-notes.swift — Export selected notes from Apple Notes.app via Scripting Bridge
// Build: swiftc -framework ScriptingBridge export-notes.swift -o export-notes
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
// Scripting Bridge's SBElementArray.value(forKey:) batches all elements into
// a single Apple Event per property — so 3 events per folder regardless of
// how many notes it contains, vs the previous approach of 3 events per note.

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

        // 3 Apple Events total for this folder — one per property
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

// MARK: - Helpers: HTML→Markdown, filename sanitisation, unique path

func htmlToMarkdown(_ html: String) -> String {
    var s = html
    let subs: [(String, String)] = [
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
    ]
    for (pattern, replacement) in subs {
        if let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            s = re.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: replacement)
        }
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

func uniquePath(dir: String, name: String, ext: String) -> String {
    let base = "\(dir)/\(name).\(ext)"
    guard fm.fileExists(atPath: base) else { return base }
    var n = 2
    while fm.fileExists(atPath: "\(dir)/\(name)_\(n).\(ext)") { n += 1 }
    return "\(dir)/\(name)_\(n).\(ext)"
}

// MARK: - Write files

let pid = ProcessInfo.processInfo.processIdentifier
for idx in selectedIndices {
    let note = filtered[idx]

    // One Apple Event per selected note to fetch content
    var content = note.ref.value(forKey: contentKey) as? String ?? ""
    if cfg.format == "md" { content = htmlToMarkdown(content) }

    let safeName = sanitize(note.name)
    let outPath  = uniquePath(dir: cfg.outDir, name: safeName, ext: fileExt)

    if cfg.format == "pdf" {
        let tmpHtml = NSTemporaryDirectory() + "note_\(pid)_\(idx).html"
        try! content.write(toFile: tmpHtml, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments  = ["wkhtmltopdf", "--quiet", tmpHtml, outPath]
        proc.launch(); proc.waitUntilExit()
        try? fm.removeItem(atPath: tmpHtml)
    } else {
        try! content.write(toFile: outPath, atomically: true, encoding: .utf8)
    }

    print("  ✓ \(note.name) → \((outPath as NSString).lastPathComponent)")
}

print("")
print("Done. Files saved to \(cfg.outDir)/")
