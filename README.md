# NotesExporter

A command-line utility to export notes from Apple Notes.app on macOS.

This was vibe coded by BluePill Software for personal use. I don't expect anyone else to be interested in it, but everyone is welcome to use it.

## Versions

There are two implementations with identical interfaces:

| | `export-notes.sh` | `export-notes` (Swift) |
|---|---|---|
| **How it works** | JXA via `osascript` subprocess | Scripting Bridge (in-process) |
| **591 notes, full export** | 2m 03s | 3.6s |
| **Speedup** | — | **~34×** |

The Swift version is recommended. It uses macOS Scripting Bridge to talk to Notes.app in-process, bulk-fetches note metadata and content using `SBElementArray` (a handful of Apple Events total rather than one per note), and writes files concurrently.

The shell script is kept as a reference implementation.

## How it works

Both versions fetch the list of all notes across every account and folder, let you filter and select the ones you want, then pull the content of each selected note and write it to a file. Notes can be exported as Markdown (default), raw HTML, plain text, or PDF (via `wkhtmltopdf`).

## Building the Swift version

```bash
make
```

The Makefile derives the version string from git tags (`git describe`) and compiles it into the binary. Run `make version` to see the current version without building.

## Usage

```
./export-notes [options]
./export-notes.sh [options]
```

Both accept the same flags.

### Options

| Flag | Description |
|------|-------------|
| `-f FORMAT` | Output format: `md`, `html`, `txt`, or `pdf` (default: `md`) |
| `-o DIR` | Output directory (default: `./exported-notes`) |
| `-a ACCOUNT` | Filter by account name (e.g. `iCloud`) |
| `-F FOLDER` | Filter by folder name |
| `-r REGEX` | Export notes whose title matches a regex (skips interactive selection) |
| `-v` | Show version |
| `-h` | Show help |

### Examples

```bash
# Interactive mode — browse and pick notes to export (default: markdown)
./export-notes

# Export as PDF
./export-notes -f pdf

# Export notes with "recipe" in the title
./export-notes -r "recipe"

# Case-insensitive match
./export-notes -r "[Mm]eeting"

# Export all recipe notes to a "notes" directory
./export-notes -o notes -r "Recipes*"

# Combine filters
./export-notes -r "TODO|FIXME" -a iCloud -f txt -o ~/Desktop/todos
```

## Requirements

- macOS
- Notes.app (launches automatically if not running)
- [`wkhtmltopdf`](https://wkhtmltopdf.org/) — required only for PDF export (`brew install wkhtmltopdf`)

## License

Copyright BluePill Software. This project is licensed under the [Creative Commons Attribution 4.0 International License (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
