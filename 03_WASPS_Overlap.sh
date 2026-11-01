#!/bin/bash

# ================================================
# WASPS-OVERLAP - Compare and Intersect Saved Searches from Script 02
# ================================================

FORMAT="md"             # 'md' or 'csv'
SORT="name"             # 'name', 'doc', or term number (e.g., 'term1', 'term2')
REVERSE=0               # 1 = flip sort direction
STRICT=0                # 1 = strict intersection (document must have hits in ALL search files)
OUTFILE=""              # empty = stdout
LABELS=""               # comma-separated custom labels for terms/files

US=$'\x1f'              # internal field delimiter

show_help() {
    echo "Usage: ./04_WASPS_Overlap.sh [OPTIONS] file1.tsv file2.tsv [file3.tsv ...]"
    echo ""
    echo "Options:"
    echo "  -i, --inputs LIST      Comma-separated list of saved search files from Script 02"
    echo "      --strict           Only show documents present in ALL input files (AND intersection)"
    echo "      --format FMT       Output format: 'md' (Default) or 'csv'"
    echo "      --sort KEY         Sort by 'name' (Folder/Doc), or column (e.g. 'term1', 'hits')"
    echo "      --reverse          Flip sort direction"
    echo "  -l, --labels LIST      Comma-separated custom column headers (e.g., 'Contracting,Waiver,Form')"
    echo "  -o, --out FILE         Write output report to FILE instead of stdout"
    echo "  -h, --help             Show this help message"
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

# ==============================================================================
# ARGUMENT PARSING
# ==============================================================================

INPUT_FILES=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -i|--inputs) 
            IFS=',' read -ra _in <<< "$2"
            INPUT_FILES+=("${_in[@]}")
            shift 2 
            ;;
        --strict) STRICT=1; shift ;;
        --format) FORMAT="${2:?missing value for $1}"; shift 2 ;;
        --sort) SORT="${2:?missing value for $1}"; shift 2 ;;
        --reverse) REVERSE=1; shift ;;
        -l|--labels) LABELS="$2"; shift 2 ;;
        -o|--out) OUTFILE="${2:?missing value for $1}"; shift 2 ;;
        -h|--help) show_help ;;
        -*) echo "Unknown parameter passed: $1"; exit 1 ;;
        *) INPUT_FILES+=("$1"); shift ;;
    esac
done

[[ ${#INPUT_FILES[@]} -ge 2 ]] || die "You must provide at least 2 saved search files to compare."
[[ "$FORMAT" == "md" || "$FORMAT" == "csv" ]] || die "--format must be 'md' or 'csv'."

# Validate input files exist
for f in "${INPUT_FILES[@]}"; do
    [[ -f "$f" ]] || die "Input search file '$f' not found."
done

# Setup custom labels or default names
CUSTOM_LABELS=()
if [[ -n "$LABELS" ]]; then
    IFS=',' read -ra CUSTOM_LABELS <<< "$LABELS"
fi

TERM_HEADERS=()
for i in "${!INPUT_FILES[@]}"; do
    if [[ -n "${CUSTOM_LABELS[$i]:-}" ]]; then
        TERM_HEADERS+=("${CUSTOM_LABELS[$i]}")
    else
        # Default label derived from filename without extension/path
        base="${INPUT_FILES[$i]##*/}"
        TERM_HEADERS+=("${base%.*}")
    fi
done

# ==============================================================================
# MERGE & PROCESSING VIA AWK
# ==============================================================================

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Combine and pivot all saved search files on (Folder, Document)
# Each saved file format from script 02: Folder \x1f Document \x1f Hits \x1f First_Match
awk -F "$US" -v num_files="${#INPUT_FILES[@]}" '
    BEGIN {
        OFS = "\x1f"
    }
    {
        folder = $1
        doc = $2
        hits = ($3 == "" ? 0 : $3)
        file_idx = ARGV[ARGC-1] # tracked via ARGIND in gawk, or loop index
    }
' "${INPUT_FILES[@]}" > /dev/null 2>&1

# Using standard AWK with ARGIND to load multiple files into a multi-dimensional array
awk -F "$US" -v num_files="${#INPUT_FILES[@]}" -v strict="$STRICT" '
    # ARGIND tracks current file index in gawk
    {
        folder = $1
        doc = $2
        hits = $3 + 0
        
        # Track unique documents
        key = folder "\x1f" doc
        if (!(key in seen_docs)) {
            seen_docs[key] = 1
            docs[++doc_count] = key
            split(key, parts, "\x1f")
            folders[key] = parts[1]
            document_names[key] = parts[2]
        }
        matrix[key, ARGIND] = hits
    }
    END {
        for (i = 1; i <= doc_count; i++) {
            k = docs[i]
            # Check strict condition if requested
            if (strict == 1) {
                valid = 1
                for (f = 1; f <= num_files; f++) {
                    if (matrix[k, f] == "" || matrix[k, f] == 0) { valid = 0; break }
                }
                if (valid == 0) continue
            }
            
            # Print row: Folder \x1f Document \x1f hit1 \x1f hit2 ...
            line = folders[k] "\x1f" document_names[k]
            for (f = 1; f <= num_files; f++) {
                h = matrix[k, f]
                line = line "\x1f" (h == "" ? 0 : h)
            }
            print line
        }
    }
' "${INPUT_FILES[@]}" > "$TMP"

# ==============================================================================
# SORTING RECORDS
# ==============================================================================

SORT_TMP=$(mktemp)
trap 'rm -f "$TMP" "$SORT_TMP"' EXIT

# Determine sort column index for sort utility
# Columns: 1=Folder, 2=Document, 3=Term1, 4=Term2, ...
sort_col=1
sort_numeric=0
ord=""
hord="nr"
if [[ $REVERSE -eq 1 ]]; then ord="r"; hord="n"; fi

if [[ "$SORT" == "name" || "$SORT" == "doc" ]]; then
    sort_col=2
    sort_numeric=0
elif [[ "$SORT" =~ ^term([0-9]+)$ ]]; then
    term_num="${BASH_REMATCH[1]}"
    sort_col=$((term_num + 2))
    sort_numeric=1
elif [[ "$SORT" =~ ^[0-9]+$ ]]; then
    sort_col="$SORT"
    sort_numeric=1
elif [[ "$SORT" == "hits" ]]; then
    # Default to sorting by the first term if generic 'hits' is requested
    sort_col=3
    sort_numeric=1
fi

if [[ $sort_numeric -eq 1 ]]; then
    LC_ALL=C sort -t "$US" -k${sort_col},${sort_col}${hord} -k1,1V -k2,2V "$TMP" > "$SORT_TMP"
else
    LC_ALL=C sort -t "$US" -k2,2V${ord} -k1,1V${ord} "$TMP" > "$SORT_TMP"
fi

# ==============================================================================
# RENDER FINAL REPORT
# ==============================================================================

# Build header string for render table
HEADER_STR="Folder,Document"
NUM_COLS_STR="3"
for i in "${!TERM_HEADERS[@]}"; do
    HEADER_STR="${HEADER_STR},${TERM_HEADERS[$i]}"
    # Mark hit columns as numeric for right-alignment in markdown tables
    col_idx=$((i + 3))
    NUM_COLS_STR="${NUM_COLS_STR},${col_idx}"
done

generate_output() {
    if [[ "$FORMAT" == "md" ]]; then
        mode_desc="Full Overlap Matrix"
        [[ $STRICT -eq 1 ]] && mode_desc="Strict Intersection (All Terms Present)"
        echo "**Analysis Mode:** $mode_desc | **Compared Terms:** ${#INPUT_FILES[@]}"
        echo ""
    fi

    # Render Table via awk
    awk -F "$US" -v fmt="$FORMAT" -v hdr="$HEADER_STR" -v numcols=",$NUM_COLS_STR," '
        function esc_md(s)  { gsub(/\|/, "\\|", s); return s }
        function esc_csv(s) { gsub(/"/, "\"\"", s); return "\"" s "\"" }
        BEGIN {
            n = split(hdr, H, ",")
            if (fmt == "md") {
                line = "|"; sep = "|"
                for (i = 1; i <= n; i++) {
                    line = line " " H[i] " |"
                    sep  = sep ((index(numcols, "," i ",") > 0) ? " ---: |" : " --- |")
                }
                print line; print sep
            } else {
                line = ""
                for (i = 1; i <= n; i++) line = line (i > 1 ? "," : "") H[i]
                print line
            }
        }
        {
            out = (fmt == "md") ? "|" : ""
            for (i = 1; i <= n; i++) {
                v = $i
                if (fmt == "md") out = out " " esc_md(v) " |"
                else out = out (i > 1 ? "," : "") ((index(numcols, "," i ",") > 0) ? v : esc_csv(v))
            }
            print out
        }' "$SORT_TMP"

    # Print summary footer
    total_docs=$(wc -l < "$SORT_TMP")
    if [[ "$FORMAT" == "md" ]]; then
        echo ""
        echo "**Total Matched Documents:** $total_docs"
    else
        echo "Total Matched Documents: $total_docs" >&2
    fi
}

if [[ -n "$OUTFILE" ]]; then
    generate_output > "$OUTFILE"
    echo "Wrote overlap report to $OUTFILE" >&2
else
    generate_output
fi
