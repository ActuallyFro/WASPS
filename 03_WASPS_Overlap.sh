#!/bin/bash

# ================================================
# WASPS-OVERLAP - Strict Intersection of Saved Searches from Script 02
# ================================================

FORMAT="md"             # 'md' or 'csv'
SORT="name"             # 'name', 'doc', or term number (e.g., 'term1', 'term2')
REVERSE=0               # 1 = flip sort direction
OUTFILE=""              # empty = stdout
LABELS=""               # comma-separated custom labels for terms/files

US=$'\x1f'              # internal field delimiter

show_help() {
    echo "Usage: ./03_WASPS_Overlap.sh [OPTIONS] file1.tsv file2.tsv [file3.tsv ...]"
    echo ""
    echo "Options:"
    echo "  -i, --inputs LIST      Comma-separated list of saved search files from Script 02"
    echo "      --format FMT       Output format: 'md' (Default) or 'csv'"
    echo "      --sort KEY         Sort by 'name' (Folder/Doc), or column (e.g. 'term1', 'hits')"
    echo "      --reverse          Flip sort direction"
    echo "  -l, --labels LIST      Comma-separated custom column headers (e.g., 'Contracting,Waiver,Form')"
    echo "  -o, --out FILE         Write output report to FILE instead of stdout"
    echo "  -h, --help             Show this help message"
    exit 1
}

die() { echo "Error: $*" >&2; exit 1; }

INPUT_FILES=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -i|--inputs) 
            IFS=',' read -ra _in <<< "$2"
            INPUT_FILES+=("${_in[@]}")
            shift 2 
            ;;
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

for f in "${INPUT_FILES[@]}"; do
    [[ -f "$f" ]] || die "Input search file '$f' not found."
done

CUSTOM_LABELS=()
if [[ -n "$LABELS" ]]; then
    IFS=',' read -ra CUSTOM_LABELS <<< "$LABELS"
fi

TERM_HEADERS=()
for i in "${!INPUT_FILES[@]}"; do
    if [[ -n "${CUSTOM_LABELS[$i]:-}" ]]; then
        TERM_HEADERS+=("${CUSTOM_LABELS[$i]}")
    else
        base="${INPUT_FILES[$i]##*/}"
        TERM_HEADERS+=("${base%.*}")
    fi
done

TMP=$(mktemp)
SORT_TMP=$(mktemp)
trap 'rm -f "$TMP" "$SORT_TMP"' EXIT

# Strict Intersection Engine with portable FILENAME tracking (compatible with mawk and gawk)
awk -F "$US" -v num_files="${#INPUT_FILES[@]}" '
    BEGIN {
        file_idx = 0
        last_file = ""
    }
    {
        # Portably track file index across mawk and gawk
        if (FILENAME != last_file) {
            last_file = FILENAME
            file_idx++
        }

        folder = $1
        doc = $2
        hits = $3 + 0
        
        key = folder "\x1f" doc
        if (!(key in seen_docs)) {
            seen_docs[key] = 1
            docs[++doc_count] = key
            split(key, parts, "\x1f")
            folders[key] = parts[1]
            document_names[key] = parts[2]
        }
        matrix[key, file_idx] = hits
    }
    END {
        for (i = 1; i <= doc_count; i++) {
            k = docs[i]
            
            # Strict Intersection check: ALL input files must have hits > 0
            valid = 1
            for (f = 1; f <= num_files; f++) {
                h = matrix[k, f] + 0
                if (h == 0) { valid = 0; break }
            }
            if (valid == 0) continue
            
            line = folders[k] "\x1f" document_names[k]
            for (f = 1; f <= num_files; f++) {
                line = line "\x1f" matrix[k, f]
            }
            print line
        }
    }
' "${INPUT_FILES[@]}" > "$TMP"

sort_col=2
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
    sort_col=3
    sort_numeric=1
fi

if [[ $sort_numeric -eq 1 ]]; then
    LC_ALL=C sort -t "$US" -k${sort_col},${sort_col}${hord} -k1,1V -k2,2V "$TMP" > "$SORT_TMP"
else
    LC_ALL=C sort -t "$US" -k2,2V${ord} -k1,1V${ord} "$TMP" > "$SORT_TMP"
fi

HEADER_STR="Folder,Document"
NUM_COLS_STR="3"
for i in "${!TERM_HEADERS[@]}"; do
    HEADER_STR="${HEADER_STR},${TERM_HEADERS[$i]}"
    col_idx=$((i + 3))
    NUM_COLS_STR="${NUM_COLS_STR},${col_idx}"
done

generate_output() {
    if [[ "$FORMAT" == "md" ]]; then
        echo "**Analysis Mode:** Strict Overlap Intersection (All Terms >= 1) | **Compared Terms:** ${#INPUT_FILES[@]}"
        echo ""
    fi

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