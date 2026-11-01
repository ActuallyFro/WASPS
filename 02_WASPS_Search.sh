#!/bin/bash

# ================================================
# WASPS-SEARCH - Search the TXT twins of downloaded PDFs
# ================================================
# Looks inside every folder named  <PDF_PREFIX>*  (default: PDFs_*), at the
# .txt files that `wasps.sh -t` created next to the PDFs.

# Default Variables
ROOT_DIR="."            # where the PDFs_* folders live
PDF_PREFIX="PDFs_"      # ONLY folders starting with this are searched
FORMAT="md"             # 'md' (read it) or 'csv' (process it later)
VIEW="statement"        # search mode: 'statement' (one row per hit) or 'document' (one row per doc)
BY="document"           # count mode: 'document' or 'folder' (roll-up)
SORT="name"             # 'name' (alphanumeric) or 'hits'
REVERSE=0               # 1 = flip the natural direction (name: A-Z, hits: high-low)
CONTEXT=0               # lines of context either side of each hit (0 = just the line)
FIXED=0                 # 1 = literal text instead of regex
CASE_SENSITIVE=0        # 1 = case-sensitive
OCCURRENCES=0           # 1 = count every occurrence (default counts matching lines)
SHOW_ZERO=0             # 1 = include documents with 0 hits in document-level tables
FOLDERS=""              # comma list of folder names (prefix optional); empty = all
OUTFILE=""              # empty = stdout
SAVEFILE=""             # empty = do not save search results for script 02
PATTERN=""
MODE=""

US=$'\x1f'              # internal field delimiter (never appears in text)

# Usage Examples:
#   Find every line mentioning a phrase (regex, case-insensitive):
#     ./02_WASPS_Search.sh -s "zero trust"
#
#   Same, but 2 lines of context around each hit, only in two folders:
#     ./02_WASPS_Search.sh -s "cyber(security)? supply chain" -C 2 -f DoDI,DoDD
#
#   Literal text (no regex), CSV out to a file:
#     ./02_WASPS_Search.sh -s "DoDI 8500.01" -F --format csv -o hits.csv
#
#   One row per document (with a sample hit):
#     ./02_WASPS_Search.sh -s "risk management framework" --view document
#
#   Summary: hits per document, most hits first:
#     ./02_WASPS_Search.sh -c "risk management framework" --sort hits
#
#   Summary rolled up per folder:
#     ./02_WASPS_Search.sh -c "risk management framework" --by folder
#
#   Different prefix / location:
#     ./02_WASPS_Search.sh -s "foo" -p Docs_ -r ~/work

show_help() {
    echo "Usage: ./02_WASPS_Search.sh [MODE] [OPTIONS]"
    echo ""
    echo "Modes (Required):"
    echo "  -s, --search PATTERN   Find matching lines (or documents, see --view)"
    echo "  -c, --count PATTERN    Summary: matches mapped to source documents"
    echo ""
    echo "Matching Options (Optional):"
    echo "  -F, --fixed            PATTERN is literal text (Default: regex, grep -E style)"
    echo "      --case             Case-sensitive (Default: case-insensitive)"
    echo "  -C, --context N        Show N lines either side of each hit (search mode)"
    echo "      --occurrences      Count every occurrence, not just matching lines"
    echo ""
    echo "Output Options (Optional):"
    echo "      --format FMT       'md' (Default) or 'csv'"
    echo "      --view VIEW        search mode: 'statement' (Default) or 'document'"
    echo "      --by WHAT          count mode: 'document' (Default) or 'folder'"
    echo "      --sort KEY         'name' (Default, alphanumeric) or 'hits'"
    echo "      --reverse          Flip sort direction (name: Z-A, hits: low-high)"
    echo "      --zero             Include documents with 0 hits in document-level tables"
    echo "  -o, --out FILE         Write output report to FILE instead of stdout"
    echo "      --save FILE        Save raw document hit records to FILE (for Script 03 overlap analysis)"
    echo ""
    echo "Scope Options (Optional):"
    echo "  -f, --folders LIST     Comma list of folders, with or without prefix (Default: all)"
    echo "  -r, --root DIR         Where the folders live (Default: $ROOT_DIR)"
    echo "  -p, --prefix STR       Folder prefix to search (Default: $PDF_PREFIX)"
    exit 1
}

# ==============================================================================
# SETUP
# ==============================================================================

die() { echo "Error: $*" >&2; exit 1; }

folder_wanted() {   # folder_wanted NAME_WITHOUT_PREFIX
    [[ -z "$FOLDERS" ]] && return 0
    [[ ",$FOLDERS," == *",$1,"* ]]
}

check_pattern() {
    [[ -n "$PATTERN" ]] || die "empty search pattern."
    if [[ $FIXED -eq 0 ]]; then
        echo "" | grep -E -e "$PATTERN" > /dev/null 2>&1
        if [[ $? -eq 2 ]]; then die "invalid regex '$PATTERN' (use -F for literal text)."; fi
    fi
}

build_grep() {
    GREP=(grep -a)
    if [[ $FIXED -eq 1 ]]; then GREP+=(-F); else GREP+=(-E); fi
    if [[ $CASE_SENSITIVE -eq 0 ]]; then GREP+=(-i); fi
}

collect_files() {
    FILES=()
    FOLDER_COUNT=0
    shopt -s nullglob
    local dir name folder f p txt missing empty

    for dir in "$ROOT_DIR"/"$PDF_PREFIX"*/; do
        name="${dir%/}"; name="${name##*/}"
        folder="${name#"$PDF_PREFIX"}"
        folder_wanted "$folder" || continue
        FOLDER_COUNT=$((FOLDER_COUNT + 1))

        missing=0; empty=0
        for p in "$dir"*.pdf; do
            txt="${p%.*}.txt"
            if [[ ! -e "$txt" ]]; then missing=$((missing + 1))
            elif [[ ! -s "$txt" ]]; then empty=$((empty + 1)); fi
        done
        if [[ $missing -gt 0 ]]; then echo "Warning: $name: $missing PDF(s) have no .txt (run: ./wasps.sh -t -w ${dir%/})" >&2; fi
        if [[ $empty -gt 0 ]];   then echo "Warning: $name: $empty empty .txt file(s) (scanned PDFs? they need OCR)" >&2; fi

        for f in "$dir"*.txt; do FILES+=("$f"); done
    done

    if [[ $FOLDER_COUNT -eq 0 ]]; then die "no folders matching '${PDF_PREFIX}*' (filter: '${FOLDERS:-none}') under '$ROOT_DIR'."; fi
    if [[ ${#FILES[@]} -eq 0 ]]; then die "no .txt files found. Run './wasps.sh -t -w <folder>' first."; fi
    echo "Searching ${#FILES[@]} text file(s) in $FOLDER_COUNT folder(s)..." >&2
}

# ==============================================================================
# PRODUCERS (write rows delimited by $US)
# ==============================================================================

search_statements() {
    local f d folder b doc
    for f in "${FILES[@]}"; do
        d="${f%/*}"; d="${d##*/}"; folder="${d#"$PDF_PREFIX"}"
        b="${f##*/}"; doc="${b%.txt}"

        if [[ $CONTEXT -gt 0 ]]; then
            "${GREP[@]}" -n -C "$CONTEXT" -e "$PATTERN" "$f"
        else
            "${GREP[@]}" -n -e "$PATTERN" "$f"
        fi | awk -v US="$US" -v folder="$folder" -v doc="$doc" -v ctx="$CONTEXT" -v fmt="$FORMAT" '
            function flush() { if (buf != "") print folder US doc US buf; buf = "" }
            $0 == "--" { flush(); next }
            {
                if (!match($0, /^[0-9]+[:-]/)) next
                sep = substr($0, RLENGTH, 1)
                txt = substr($0, RLENGTH + 1)
                gsub("\f", "", txt); gsub(/[ \t\r]+/, " ", txt)
                sub(/^ /, "", txt); sub(/ $/, "", txt)
                hit = (sep == ":")
                if (ctx == 0) { if (hit && txt != "") print folder US doc US txt; next }
                if (txt == "") next
                if (hit) txt = (fmt == "md") ? "**" txt "**" : ">> " txt
                buf = (buf == "") ? txt : buf " ⏎ " txt
            }
            END { flush() }'
    done
}

doc_records() {
    local f d folder b doc hits first
    for f in "${FILES[@]}"; do
        d="${f%/*}"; d="${d##*/}"; folder="${d#"$PDF_PREFIX"}"
        b="${f##*/}"; doc="${b%.txt}"

        if [[ $OCCURRENCES -eq 1 ]]; then
            hits=$(( $("${GREP[@]}" -o -e "$PATTERN" "$f" | wc -l) ))
        else
            hits=$(( $("${GREP[@]}" -c -e "$PATTERN" "$f") ))
        fi

        first=""
        if [[ "$MODE" == "search" && $hits -gt 0 ]]; then
            first=$("${GREP[@]}" -m 1 -e "$PATTERN" "$f" | tr -d '\f' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
        fi
        printf '%s%s%s%s%s%s%s\n' "$folder" "$US" "$doc" "$US" "$hits" "$US" "$first"
    done
}

filter_zero() { awk -F "$US" -v z="$SHOW_ZERO" 'z == 1 || $3 > 0'; }

rollup() {
    awk -F "$US" -v US="$US" '
        { s[$1]++; if ($3 > 0) m[$1]++; h[$1] += $3 }
        END { for (f in s) print f US s[f] US (m[f] + 0) US h[f] }'
}

sort_records() {
    local hc="$1" lv="$2" ord="" hord="nr" keys=()
    if [[ $REVERSE -eq 1 ]]; then ord="r"; hord="n"; fi
    if [[ "$SORT" == "hits" ]]; then
        keys+=("-k${hc},${hc}${hord}" "-k1,1V")
        if [[ $lv -eq 2 ]]; then keys+=("-k2,2V"); fi
    else
        keys+=("-k1,1V${ord}")
        if [[ $lv -eq 2 ]]; then keys+=("-k2,2V${ord}"); fi
    fi
    LC_ALL=C sort -t "$US" "${keys[@]}"
}

# ==============================================================================
# RENDERER
# ==============================================================================

render_table() {
    awk -F "$US" -v fmt="$FORMAT" -v hdr="$1" -v numcols=",$2," '
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
        }'
}

print_footer() {
    if [[ "$FORMAT" == "md" ]]; then echo ""; echo "$1"; else echo "${1//\*\*/}" >&2; fi
}

print_intro() {
    [[ "$FORMAT" == "md" ]] || return 0
    local kind="regex"; [[ $FIXED -eq 1 ]] && kind="literal"
    local cs="case-insensitive"; [[ $CASE_SENSITIVE -eq 1 ]] && cs="case-sensitive"
    echo "**Pattern:** \`$PATTERN\` ($kind, $cs) | **Folders:** ${FOLDERS:-all ${PDF_PREFIX}*}"
    echo ""
}

# ==============================================================================
# MODES
# ==============================================================================

run_search() {
    local label unit rows docs

    if [[ "$VIEW" == "statement" ]]; then
        search_statements > "$TMP"
        label="Statement"; unit="statement(s)"
        if [[ $CONTEXT -gt 0 ]]; then label="Context"; unit="context block(s)"; fi

        print_intro
        render_table "Folder,Document,$label" "" < "$TMP"
        read -r rows docs <<< "$(awk -F "$US" 'NF { r++; d[$1 FS $2] = 1 } END { m = 0; for (k in d) m++; print r + 0, m + 0 }' "$TMP")"
        if [[ "$rows" -eq 0 ]]; then print_footer "No matches."; else print_footer "**Total:** $rows $unit in $docs of ${#FILES[@]} document(s) ($FOLDER_COUNT folder(s))"; fi
    else
        doc_records | filter_zero | sort_records 3 2 > "$TMP"
        print_intro
        render_table "Folder,Document,Hits,First_Match" "3" < "$TMP"
        report_doc_totals
    fi
}

run_count() {
    print_intro
    if [[ "$BY" == "document" ]]; then
        doc_records | filter_zero | sort_records 3 2 > "$TMP"
        render_table "Folder,Document,Hits" "3" < "$TMP"
        report_doc_totals
    else
        doc_records | rollup | sort_records 4 1 > "$TMP"
        render_table "Folder,Docs_Searched,Docs_Matched,Hits" "2,3,4" < "$TMP"
        local hits matched
        read -r hits matched <<< "$(awk -F "$US" '{ h += $4; m += $3 } END { print h + 0, m + 0 }' "$TMP")"
        print_footer "**Total:** $hits ${HIT_UNIT} in $matched of ${#FILES[@]} document(s) ($FOLDER_COUNT folder(s))"
    fi
}

report_doc_totals() {
    local hits matched
    read -r hits matched <<< "$(awk -F "$US" '{ h += $3; if ($3 > 0) m++ } END { print h + 0, m + 0 }' "$TMP")"
    if [[ "$hits" -eq 0 ]]; then print_footer "No matches."; else print_footer "**Total:** $hits ${HIT_UNIT} in $matched of ${#FILES[@]} document(s) ($FOLDER_COUNT folder(s))"; fi
}

# ==============================================================================
# ARGUMENT ROUTER
# ==============================================================================

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -s|--search) MODE="search"; PATTERN="${2:?missing pattern for $1}"; shift 2 ;;
        -c|--count)  MODE="count";  PATTERN="${2:?missing pattern for $1}"; shift 2 ;;
        -F|--fixed) FIXED=1; shift ;;
        --case) CASE_SENSITIVE=1; shift ;;
        -C|--context) CONTEXT="${2:?missing value for $1}"; shift 2 ;;
        --occurrences) OCCURRENCES=1; shift ;;
        --format) FORMAT="${2:?missing value for $1}"; shift 2 ;;
        --view) VIEW="${2:?missing value for $1}"; shift 2 ;;
        --by) BY="${2:?missing value for $1}"; shift 2 ;;
        --sort) SORT="${2:?missing value for $1}"; shift 2 ;;
        --reverse) REVERSE=1; shift ;;
        --zero) SHOW_ZERO=1; shift ;;
        -o|--out) OUTFILE="${2:?missing value for $1}"; shift 2 ;;
        --save) SAVEFILE="${2:?missing value for $1}"; shift 2 ;;
        -f|--folders) FOLDERS="${2:?missing value for $1}"; shift 2 ;;
        -r|--root) ROOT_DIR="${2:?missing value for $1}"; shift 2 ;;
        -p|--prefix) PDF_PREFIX="${2:?missing value for $1}"; shift 2 ;;
        -h|--help) show_help ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

[[ -n "$MODE" ]] || { echo "Error: You must specify a mode (-s or -c)."; show_help; }

[[ "$FORMAT" == "md" || "$FORMAT" == "csv" ]]         || die "--format must be 'md' or 'csv'."
[[ "$VIEW" == "statement" || "$VIEW" == "document" ]] || die "--view must be 'statement' or 'document'."
[[ "$BY" == "document" || "$BY" == "folder" ]]        || die "--by must be 'document' or 'folder'."
[[ "$SORT" == "name" || "$SORT" == "hits" ]]          || die "--sort must be 'name' or 'hits'."
[[ "$CONTEXT" =~ ^[0-9]+$ ]]                          || die "--context must be a whole number."

if [[ -n "$FOLDERS" ]]; then
    NORM=""
    IFS=',' read -ra _f <<< "$FOLDERS"
    for x in "${_f[@]}"; do x="${x#"$PDF_PREFIX"}"; NORM="${NORM:+$NORM,}$x"; done
    FOLDERS="$NORM"
fi

HIT_UNIT="matching line(s)"
if [[ $OCCURRENCES -eq 1 ]]; then HIT_UNIT="occurrence(s)"; fi

check_pattern
build_grep
collect_files

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# Generate full report to temporary buffer or direct output
case "$MODE" in
    search) run_search ;;
    count)  run_count ;;
esac > "$TMP"

# If --save is requested, export the clean document hit matrix records (Folder US Doc US Hits US First_Match)
if [[ -n "$SAVEFILE" ]]; then
    doc_records | filter_zero > "$SAVEFILE"
    echo "Saved search hit records to $SAVEFILE" >&2
fi

# Output handling
if [[ -n "$OUTFILE" ]]; then
    cat "$TMP" > "$OUTFILE"
    echo "Wrote $OUTFILE" >&2
else
    cat "$TMP"
fi