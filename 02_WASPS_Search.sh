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
SAVEFILE=""             # empty = do not save search records for script 03 overlap analysis
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
#   Literal text (no regex), CSV out to a file, and save records for Script 03:
#     ./02_WASPS_Search.sh -s "DoDI 8500.01" -F --format csv -o hits.csv --save term1.tsv
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
    echo "  -o, --out FILE         Write report to FILE instead of stdout"
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

if [[ -n "$OUTFILE" ]]; then exec > "$OUTFILE"; fi

print_intro

# Initialize save file if requested
if [[ -n "$SAVEFILE" ]]; then
    : > "$SAVEFILE"
fi

total_statements_count=0
matched_docs_count=0

# ==============================================================================
# STREAMING EXECUTION ENGINE (Zero Disk Buffering)
# ==============================================================================

if [[ "$MODE" == "search" ]]; then
    if [[ "$VIEW" == "statement" ]]; then
        # Stream statements directly to render_table without intermediate temp files
        {
            for f in "${FILES[@]}"; do
                d="${f%/*}"; d="${d##*/}"; folder="${d#"$PDF_PREFIX"}"
                b="${f##*/}"; doc="${b%.txt}"

                if [[ $OCCURRENCES -eq 1 ]]; then
                    hits=$(( $("${GREP[@]}" -o -e "$PATTERN" "$f" | wc -l) ))
                else
                    hits=$(( $("${GREP[@]}" -c -e "$PATTERN" "$f") ))
                fi

                if [[ $hits -gt 0 ]]; then
                    matched_docs_count=$((matched_docs_count + 1))
                    
                    if [[ -n "$SAVEFILE" ]]; then
                        first=$("${GREP[@]}" -m 1 -e "$PATTERN" "$f" | tr -d '\f' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
                        printf '%s%s%s%s%d%s%s\n' "$folder" "$US" "$doc" "$US" "$hits" "$US" "$first" >> "$SAVEFILE"
                    fi

                    if [[ $CONTEXT -gt 0 ]]; then
                        "${GREP[@]}" -n -C "$CONTEXT" -e "$PATTERN" "$f"
                    else
                        "${GREP[@]}" -n -e "$PATTERN" "$f"
                    fi | awk -v US="$US" -v folder="$folder" -v doc="$doc" -v ctx="$CONTEXT" -v fmt="$FORMAT" '
                        function flush() { if (buf != "") { print folder US doc US buf; st_count++ }; buf = "" }
                        $0 == "--" { flush(); next }
                        {
                            if (!match($0, /^[0-9]+[:-]/)) next
                            sep = substr($0, RLENGTH, 1)
                            txt = substr($0, RLENGTH + 1)
                            gsub("\f", "", txt); gsub(/[ \t\r]+/, " ", txt)
                            sub(/^ /, "", txt); sub(/ $/, "", txt)
                            hit = (sep == ":")
                            if (ctx == 0) { if (hit && txt != "") { print folder US doc US txt; st_count++ }; next }
                            if (txt == "") next
                            if (hit) txt = (fmt == "md") ? "**" txt "**" : ">> " txt
                            buf = (buf == "") ? txt : buf " ⏎ " txt
                        }
                        END { flush() }'
                fi
            done
        } | render_type="statement" render_table "Folder,Document,Statement" ""
        
        if [[ -n "$SAVEFILE" && -f "$SAVEFILE" ]]; then
            total_statements=$(awk -F "$US" '{s+=$3} END {print s+0}' "$SAVEFILE")
            total_docs=$(wc -l < "$SAVEFILE")
            print_footer "**Total:** $total_statements statement(s) in $total_docs of ${#FILES[@]} document(s) ($FOLDER_COUNT folder(s))"
        else
            print_footer "Search complete."
        fi
    else
        # Document view: stream records directly
        {
            for f in "${FILES[@]}"; do
                d="${f%/*}"; d="${d##*/}"; folder="${d#"$PDF_PREFIX"}"
                b="${f##*/}"; doc="${b%.txt}"

                if [[ $OCCURRENCES -eq 1 ]]; then
                    hits=$(( $("${GREP[@]}" -o -e "$PATTERN" "$f" | wc -l) ))
                else
                    hits=$(( $("${GREP[@]}" -c -e "$PATTERN" "$f") ))
                fi

                if [[ $SHOW_ZERO -eq 1 || $hits -gt 0 ]]; then
                    first=""
                    if [[ $hits -gt 0 ]]; then
                        first=$("${GREP[@]}" -m 1 -e "$PATTERN" "$f" | tr -d '\f' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
                    fi
                    printf '%s%s%s%s%d%s%s\n' "$folder" "$US" "$doc" "$US" "$hits" "$US" "$first"
                    if [[ -n "$SAVEFILE" && $hits -gt 0 ]]; then
                        printf '%s%s%s%s%d%s%s\n' "$folder" "$US" "$doc" "$US" "$hits" "$US" "$first" >> "$SAVEFILE"
                    fi
                fi
            done
        } | {
            # Sort stream safely without large temp disk footprint using sort key 3 numeric
            local ord="" hord="nr"
            if [[ $REVERSE -eq 1 ]]; then ord="r"; hord="n"; fi
            if [[ "$SORT" == "hits" ]]; then
                LC_ALL=C sort -t "$US" -k3,3${hord} -k1,1V -k2,2V
            else
                LC_ALL=C sort -t "$US" -k1,1V${ord} -k2,2V${ord}
            fi
        } | render_table "Folder,Document,Hits,First_Match" "3"
        
        if [[ -n "$SAVEFILE" && -f "$SAVEFILE" ]]; then
            total_hits=$(awk -F "$US" '{h+=$3; if($3>0)m++} END {print h+0, m+0}' "$SAVEFILE")
            read -r h m <<< "$total_hits"
            print_footer "**Total:** $h matching line(s) in $m of ${#FILES[@]} document(s) ($FOLDER_COUNT folder(s))"
        fi
    fi
elif [[ "$MODE" == "count" ]]; then
    # Count mode streaming
    {
        for f in "${FILES[@]}"; do
            d="${f%/*}"; d="${d##*/}"; folder="${d#"$PDF_PREFIX"}"
            b="${f##*/}"; doc="${b%.txt}"

            if [[ $OCCURRENCES -eq 1 ]]; then
                hits=$(( $("${GREP[@]}" -o -e "$PATTERN" "$f" | wc -l) ))
            else
                hits=$(( $("${GREP[@]}" -c -e "$PATTERN" "$f") ))
            fi

            first=""
            if [[ $hits -gt 0 ]]; then
                first=$("${GREP[@]}" -m 1 -e "$PATTERN" "$f" | tr -d '\f' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//')
            fi
            printf '%s%s%s%s%d%s%s\n' "$folder" "$US" "$doc" "$US" "$hits" "$US" "$first"
            if [[ -n "$SAVEFILE" && $hits -gt 0 ]]; then
                printf '%s%s%s%s%d%s%s\n' "$folder" "$US" "$doc" "$US" "$hits" "$US" "$first" >> "$SAVEFILE"
            fi
        done
    } | {
        if [[ "$BY" == "document" ]]; then
            awk -F "$US" -v z="$SHOW_ZERO" 'z == 1 || $3 > 0' | sort -t "$US" -k3,3nr -k1,1V -k2,2V
        else
            awk -F "$US" -v US="$US" '
                { s[$1]++; if ($3 > 0) m[$1]++; h[$1] += $3 }
                END { for (f in s) print f US s[f] US (m[f] + 0) US h[f] }' | sort -t "$US" -k4,4nr -k1,1V
        fi
    } | if [[ "$BY" == "document" ]]; then
        render_table "Folder,Document,Hits" "3"
    else
        render_table "Folder,Docs_Searched,Docs_Matched,Hits" "2,3,4"
    fi
fi

if [[ -n "$OUTFILE" ]]; then echo "Wrote $OUTFILE" >&2; fi