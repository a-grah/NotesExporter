# NotesExporter

A command-line utility to export notes from Apple Notes.app on macOS.

This was vibe coded by BluePill Software for personal use. I don't expect anyone else to be interested in it, but everyone is welcome to use it.

## How it works

The script uses macOS JavaScript for Automation (JXA) to talk to Notes.app through its scripting interface. It fetches the list of all notes across every account and folder, lets you filter and select the ones you want, then pulls the content of each selected note and writes it to a file. Notes can be exported as Markdown (default), raw HTML, plain text, or PDF (via `wkhtmltopdf`).

## Usage

```
./export-notes.sh [options]
```

### Options

| Flag | Description |
|------|-------------|
| `-f FORMAT` | Output format: `md`, `html`, `txt`, or `pdf` (default: `md`) |
| `-o DIR` | Output directory (default: `./exported-notes`) |
| `-a ACCOUNT` | Filter by account name (e.g. `iCloud`) |
| `-F FOLDER` | Filter by folder name |
| `-r REGEX` | Export notes whose title matches a regex (skips interactive selection) |
| `-h` | Show help |

### Examples

```bash
# Interactive mode — browse and pick notes to export (default: markdown)
./export-notes.sh

# Export as PDF
./export-notes.sh -f pdf

# Export notes with "recipe" in the title
./export-notes.sh -r "recipe"

# Case-insensitive match
./export-notes.sh -r "[Mm]eeting"

# Export all recipe notes to a "notes" directory
./export-notes.sh -o notes -r "Recipes*"

# Combine filters
./export-notes.sh -r "TODO|FIXME" -a iCloud -f txt -o ~/Desktop/todos
```

## Requirements

- macOS
- Notes.app (launches automatically if not running)
- [`wkhtmltopdf`](https://wkhtmltopdf.org/) — required only for PDF export (`brew install wkhtmltopdf`)

## License

Copyright BluePill Software. This project is licensed under the [Creative Commons Attribution 4.0 International License (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).
