#!/bin/bash
set -euo pipefail

# export-notes.sh — Export selected notes from Apple Notes.app
# Usage: ./export-notes.sh [-f format] [-o outdir] [-a account] [-F folder] [-r regex]
#
# Formats: html (default), txt, md
# Notes.app must be running or will be launched automatically by osascript.

FORMAT="html"
OUTDIR="./exported-notes"
ACCOUNT=""
FOLDER=""
REGEX=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -f FORMAT   Output format: html, txt, md (default: html)
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

if [[ "$FORMAT" != "html" && "$FORMAT" != "txt" && "$FORMAT" != "md" ]]; then
    echo "Error: format must be html, txt, or md" >&2
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
while IFS= read -r line; do
    acct=$(echo "$line" | cut -f1)
    fldr=$(echo "$line" | cut -f2)
    name=$(echo "$line" | cut -f3)
    if [[ -n "$ACCOUNT" && "$acct" != "$ACCOUNT" ]]; then continue; fi
    if [[ -n "$FOLDER" && "$fldr" != "$FOLDER" ]]; then continue; fi
    if [[ -n "$REGEX" ]] && ! echo "$name" | grep -qE "$REGEX"; then continue; fi
    FILTERED+="$line"$'\n'
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
while IFS= read -r line; do
    acct=$(echo "$line" | cut -f1)
    fldr=$(echo "$line" | cut -f2)
    name=$(echo "$line" | cut -f3)
    moddate=$(echo "$line" | cut -f4 | cut -c1-10)
    nid=$(echo "$line" | cut -f5)
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

for idx in "${SELECTED[@]}"; do
    nid="${NOTE_IDS[$((idx-1))]}"
    raw_name="${NOTE_NAMES[$((idx-1))]}"
    # Sanitise filename
    safe_name=$(echo "$raw_name" | sed 's/[\/\\:*?"<>|]/_/g' | sed 's/^\.*//' | head -c 200)
    if [[ -z "$safe_name" ]]; then safe_name="untitled"; fi

    case "$FORMAT" in
        html)
            ext="html"
            body_field="htmlBody"
            ;;
        txt)
            ext="txt"
            body_field="plaintext"
            ;;
        md)
            ext="md"
            body_field="htmlBody"
            ;;
    esac

    CONTENT=$(osascript -l JavaScript - "$nid" "$body_field" <<'ENDJS'
const args = $.NSProcessInfo.processInfo.arguments;
const noteId = ObjC.unwrap(args.objectAtIndex(4));
const field = ObjC.unwrap(args.objectAtIndex(5));

const Notes = Application("Notes");
const allNotes = Notes.notes.whose({id: noteId})();
if (allNotes.length === 0) {
    "";
} else {
    const note = allNotes[0];
    if (field === "plaintext") {
        note.plaintext();
    } else {
        note.body();
    }
}
ENDJS
    )

    # For markdown output, convert HTML to a rough markdown
    if [[ "$FORMAT" == "md" ]]; then
        CONTENT=$(echo "$CONTENT" \
            | sed 's/<br[^>]*>/\n/gi' \
            | sed 's/<\/p>/\n\n/gi' \
            | sed 's/<\/h1>/\n\n/gi' \
            | sed 's/<\/h2>/\n\n/gi' \
            | sed 's/<\/h3>/\n\n/gi' \
            | sed 's/<h1[^>]*>/# /gi' \
            | sed 's/<h2[^>]*>/## /gi' \
            | sed 's/<h3[^>]*>/### /gi' \
            | sed 's/<\/li>/\n/gi' \
            | sed 's/<li[^>]*>/- /gi' \
            | sed 's/<strong[^>]*>/\*\*/gi' \
            | sed 's/<\/strong>/\*\*/gi' \
            | sed 's/<em[^>]*>/\*/gi' \
            | sed 's/<\/em>/\*/gi' \
            | sed 's/<[^>]*>//g' \
            | sed '/^[[:space:]]*$/{ N; /^\n[[:space:]]*$/d; }' \
        )
    fi

    OUTFILE="$OUTDIR/${safe_name}.${ext}"

    # Avoid clobbering: append number if file exists
    if [[ -e "$OUTFILE" ]]; then
        counter=2
        while [[ -e "$OUTDIR/${safe_name}_${counter}.${ext}" ]]; do
            ((counter++))
        done
        OUTFILE="$OUTDIR/${safe_name}_${counter}.${ext}"
    fi

    echo "$CONTENT" > "$OUTFILE"
    echo "  ✓ $raw_name → $(basename "$OUTFILE")"
done

echo ""
echo "Done. Files saved to $OUTDIR/"
