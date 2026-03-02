#!/bin/bash
set -euo pipefail

# export-notes.sh — Export selected notes from Apple Notes.app
# Usage: ./export-notes.sh [-f format] [-o outdir] [-a account] [-F folder] [-r regex]
#
# Formats: md (default), html, txt, pdf
# Notes.app must be running or will be launched automatically by osascript.

FORMAT="md"
OUTDIR="./exported-notes"
ACCOUNT=""
FOLDER=""
REGEX=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -f FORMAT   Output format: md, html, txt, pdf (default: md)
  -o DIR      Output directory (default: ./exported-notes)
  -a ACCOUNT  Filter by account name (e.g. "iCloud")
  -F FOLDER   Filter by folder name
  -r REGEX    Export notes whose title matches this regex (skips interactive selection)
  -h          Show this help
EOF
    exit 0
}

while getopts "f:o:a:F:r:h" opt; do
    case "$opt" in
        f) FORMAT="$OPTARG" ;;
        o) OUTDIR="$OPTARG" ;;
        a) ACCOUNT="$OPTARG" ;;
        F) FOLDER="$OPTARG" ;;
        r) REGEX="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ "$FORMAT" != "html" && "$FORMAT" != "txt" && "$FORMAT" != "md" && "$FORMAT" != "pdf" ]]; then
    echo "Error: format must be md, html, txt, or pdf" >&2
    exit 1
fi

# Check for wkhtmltopdf if PDF format requested
if [[ "$FORMAT" == "pdf" ]] && ! command -v wkhtmltopdf &>/dev/null; then
    echo "Error: 'wkhtmltopdf' is required for PDF export but was not found." >&2
    echo "Install it with: brew install wkhtmltopdf" >&2
    exit 1
fi

# ── Step 1: Fetch note list from Notes.app ──────────────────────────────────

echo "Reading notes from Notes.app..."

NOTE_LIST=$(osascript -l JavaScript <<'ENDJS'
const Notes = Application("Notes");
Notes.includeStandardAdditions = true;

const rows = [];

const accounts = Notes.accounts();
for (const acct of accounts) {
    const folders = acct.folders();
    for (const folder of folders) {
        const notes = folder.notes();
        for (const note of notes) {
            const name = note.name();
            const modDate = note.modificationDate().toISOString();
            const acctName = acct.name();
            const folderName = folder.name();
            const noteId = note.id();
            // Tab-separated: index placeholder | account | folder | name | date | id
            rows.push([acctName, folderName, name, modDate, noteId].join("\t"));
        }
    }
}

rows.join("\n");
ENDJS
)

if [[ -z "$NOTE_LIST" ]]; then
    echo "No notes found."
    exit 0
fi

# ── Step 2: Apply filters ───────────────────────────────────────────────────

FILTERED=""
while IFS=$'\t' read -r acct fldr name rest; do
    if [[ -n "$ACCOUNT" && "$acct" != "$ACCOUNT" ]]; then continue; fi
    if [[ -n "$FOLDER" && "$fldr" != "$FOLDER" ]]; then continue; fi
    if [[ -n "$REGEX" && ! "$name" =~ $REGEX ]]; then continue; fi
    FILTERED+="${acct}"$'\t'"${fldr}"$'\t'"${name}"$'\t'"${rest}"$'\n'
done <<< "$NOTE_LIST"

FILTERED="${FILTERED%$'\n'}"  # trim trailing newline

if [[ -z "$FILTERED" ]]; then
    echo "No notes match the given filters."
    exit 0
fi

# ── Step 3: Display list and let user pick ──────────────────────────────────

echo ""
printf "%-5s  %-15s  %-20s  %-12s  %s\n" "#" "ACCOUNT" "FOLDER" "MODIFIED" "TITLE"
printf "%-5s  %-15s  %-20s  %-12s  %s\n" "---" "---------------" "--------------------" "------------" "-----"

IDX=1
declare -a NOTE_IDS
declare -a NOTE_NAMES
while IFS=$'\t' read -r acct fldr name moddate nid; do
    moddate="${moddate:0:10}"
    printf "%-5s  %-15s  %-20s  %-12s  %s\n" "$IDX" "$acct" "$fldr" "$moddate" "$name"
    NOTE_IDS+=("$nid")
    NOTE_NAMES+=("$name")
    ((IDX++))
done <<< "$FILTERED"

TOTAL=${#NOTE_IDS[@]}
declare -a SELECTED=()

if [[ -n "$REGEX" ]]; then
    # Regex mode: auto-select all matched notes, no interactive prompt
    for ((i=1; i<=TOTAL; i++)); do
        SELECTED+=("$i")
    done
else
    echo ""
    echo "Found $TOTAL note(s). Enter selection:"
    echo "  - Individual numbers: 1 3 5"
    echo "  - Ranges: 2-7"
    echo "  - All: a"
    echo "  - Quit: q"
    echo ""
    read -rp "Selection: " SELECTION

    if [[ "$SELECTION" == "q" ]]; then
        echo "Cancelled."
        exit 0
    fi

    # Parse selection into an array of indices
    if [[ "$SELECTION" == "a" || "$SELECTION" == "A" ]]; then
        for ((i=1; i<=TOTAL; i++)); do
            SELECTED+=("$i")
        done
    else
        for token in $SELECTION; do
            if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                start=${BASH_REMATCH[1]}
                end=${BASH_REMATCH[2]}
                for ((i=start; i<=end; i++)); do
                    if ((i >= 1 && i <= TOTAL)); then
                        SELECTED+=("$i")
                    fi
                done
            elif [[ "$token" =~ ^[0-9]+$ ]]; then
                if ((token >= 1 && token <= TOTAL)); then
                    SELECTED+=("$token")
                else
                    echo "Warning: #$token out of range, skipping." >&2
                fi
            else
                echo "Warning: unrecognised token '$token', skipping." >&2
            fi
        done
    fi
fi

if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "Nothing selected."
    exit 0
fi

# ── Step 4: Export selected notes ────────────────────────────────────────────

mkdir -p "$OUTDIR"

echo ""
echo "Exporting ${#SELECTED[@]} note(s) as $FORMAT to $OUTDIR/ ..."

# Determine extension and body field (fixed for the whole run)
case "$FORMAT" in
    html) ext="html"; BODY_FIELD="htmlBody" ;;
    txt)  ext="txt";  BODY_FIELD="plaintext" ;;
    md)   ext="md";   BODY_FIELD="htmlBody" ;;
    pdf)  ext="pdf";  BODY_FIELD="htmlBody" ;;
esac

# Pre-compute IDs and sanitised filenames for all selected notes
declare -a BATCH_IDS=()
declare -a BATCH_RAW_NAMES=()
declare -a BATCH_SAFE_NAMES=()
for idx in "${SELECTED[@]}"; do
    BATCH_IDS+=("${NOTE_IDS[$((idx-1))]}")
    raw_name="${NOTE_NAMES[$((idx-1))]}"
    BATCH_RAW_NAMES+=("$raw_name")
    safe_name="${raw_name//[\/\\:*?"<>|]/_}"
    while [[ "$safe_name" == .* ]]; do safe_name="${safe_name#.}"; done
    safe_name="${safe_name:0:200}"
    [[ -z "$safe_name" ]] && safe_name="untitled"
    BATCH_SAFE_NAMES+=("$safe_name")
done

# Write IDs to a temp file; fetch all content in a single osascript call.
# Entries in the output are joined with ASCII RS (0x1E) for safe splitting.
TMPIDS=$(mktemp /tmp/note_ids_XXXXXX.txt)
printf '%s\n' "${BATCH_IDS[@]}" > "$TMPIDS"

BATCH_CONTENT=$(osascript -l JavaScript - "$TMPIDS" "$BODY_FIELD" <<'ENDJS'
ObjC.import('Foundation');
const args  = $.NSProcessInfo.processInfo.arguments;
const idsFile = ObjC.unwrap(args.objectAtIndex(4));
const field   = ObjC.unwrap(args.objectAtIndex(5));

const raw = $.NSString.alloc.initWithDataEncoding(
    $.NSData.dataWithContentsOfFile(idsFile),
    $.NSUTF8StringEncoding
);
const noteIds = ObjC.unwrap(raw).trim().split('\n').filter(id => id.length > 0);

const Notes = Application("Notes");
const results = [];
for (const noteId of noteIds) {
    const matches = Notes.notes.whose({id: noteId})();
    if (matches.length === 0) {
        results.push("");
    } else {
        const note = matches[0];
        results.push(field === "plaintext" ? note.plaintext() : note.body());
    }
}
results.join("\x1e");
ENDJS
)
rm -f "$TMPIDS"

# Process and write each note; split BATCH_CONTENT on ASCII RS (0x1E)
i=0
while IFS= read -r -d $'\x1e' CONTENT || [[ -n "$CONTENT" ]]; do
    raw_name="${BATCH_RAW_NAMES[$i]}"
    safe_name="${BATCH_SAFE_NAMES[$i]}"
    i=$(( i + 1 ))

    # For markdown output, convert HTML to rough markdown in a single sed pass
    if [[ "$FORMAT" == "md" ]]; then
        CONTENT=$(echo "$CONTENT" | sed \
            -e 's/<br[^>]*>/\n/gi' \
            -e 's/<\/p>/\n\n/gi' \
            -e 's/<\/h1>/\n\n/gi' \
            -e 's/<\/h2>/\n\n/gi' \
            -e 's/<\/h3>/\n\n/gi' \
            -e 's/<h1[^>]*>/# /gi' \
            -e 's/<h2[^>]*>/## /gi' \
            -e 's/<h3[^>]*>/### /gi' \
            -e 's/<\/li>/\n/gi' \
            -e 's/<li[^>]*>/- /gi' \
            -e 's/<strong[^>]*>/\*\*/gi' \
            -e 's/<\/strong>/\*\*/gi' \
            -e 's/<em[^>]*>/\*/gi' \
            -e 's/<\/em>/\*/gi' \
            -e 's/<[^>]*>//g' \
            -e '/^[[:space:]]*$/{ N; /^\n[[:space:]]*$/d; }' \
        )
    fi

    OUTFILE="$OUTDIR/${safe_name}.${ext}"

    # Avoid clobbering: append a counter if the file already exists
    if [[ -e "$OUTFILE" ]]; then
        counter=2
        while [[ -e "$OUTDIR/${safe_name}_${counter}.${ext}" ]]; do
            ((counter++))
        done
        OUTFILE="$OUTDIR/${safe_name}_${counter}.${ext}"
    fi

    if [[ "$FORMAT" == "pdf" ]]; then
        TMPFILE=$(mktemp /tmp/note_XXXXXX.html)
        echo "$CONTENT" > "$TMPFILE"
        wkhtmltopdf --quiet "$TMPFILE" "$OUTFILE"
        rm -f "$TMPFILE"
    else
        echo "$CONTENT" > "$OUTFILE"
    fi
    echo "  ✓ $raw_name → $(basename "$OUTFILE")"
done <<< "$BATCH_CONTENT"

echo ""
echo "Done. Files saved to $OUTDIR/"
