#!/bin/bash

# ================================================
# WASPS - Website Asset Search & Processing System
# ================================================

# Default Variables
INPUT_FILE="wasps_input.html"   # HTML file OR an http(s):// URL
MD_FILE="wasps_extracted.md"
DOWNLOAD_DIR="wasps_downloads"
PARSER_MODE="generic"
ALLOWED_EXT="pdf|doc|docx|xls|xlsx|ppt|pptx|zip|xml|csv"
DELAY=2
MODE=""
VERBOSE=0
MIN_PAGES=120
INSECURE=1      # 1 = curl -k (skip TLS verification). Use --secure to turn off.
VALIDATE=1      # 1 = reject downloads that are really HTML login/error pages. --no-validate to turn off.
REFERER=""      # Optional. Defaults to BASE_URL.
BASE_URL_SET=0

BASE_URL="https://wikis.mit.edu/"

# Usage Examples:
#   Parse HTML to Markdown:
#     ./wasps.sh -p -i wasps_input.html -m wasps_extracted.md
#
#   Parse a live page instead of a saved file (uses the cURL headers/cookies below):
#     ./wasps.sh -p -i https://wikis.mit.edu/confluence/display/XYZ -m wasps_extracted.md
#
#   Download PDFs from Markdown:
#     ./wasps.sh -d -m wasps_extracted.md -w wasps_downloads
#
#   Parse and Download (All-in-one execution):
#     ./wasps.sh -a -i wasps_input.html -m wasps_extracted.md -w wasps_downloads
#
#   Convert Downloaded PDFs to Text:
#     ./wasps.sh -t -w wasps_downloads
#
#   Search PDFs by Minimum Page Count (e.g., 120+ pages):
#     ./wasps.sh -s -n 120 -w wasps_downloads

# ==============================================================================
# HOW TO EXTEND WASPS FOR NEW SITES:
# 
# 1. ADDING CURL HEADERS:
#    Paste your Chrome "Copy as cURL" command between the 'EOF' tags below.
#    WASPS dynamically extracts cookies (-b), headers (-H), user-agent (-A) and
#    referer (-e) for downloads. Lines starting with # are ignored.
#    Headers that break plain-curl downloads are skipped automatically
#    (accept-encoding, if-none-match, if-modified-since, range, host, ...);
#    WASPS adds --compressed itself.
#    Sites that need a login: refresh the cookies here when downloads start
#    failing -- WASPS reports (and keeps as .rejected) any "download" that is
#    really an HTML login page.
#
# 2. ADDING A NEW PARSER:
#    If a site requires specific HTML parsing (likely needing metadata extraction),
#    scroll down to the `parse_html()` function.
#    Add a new block to the `case "$PARSER_MODE" in` statement.
#    Output your results to $MD_FILE in this exact format:
#       * [Clean_Filename.ext](https://full.download.url/file.ext)
#    (Duplicate URLs and duplicate filenames are cleaned up automatically
#    after your block runs.)
# ==============================================================================

read -r -d '' CHROME_CURL << 'EOF'
curl 'https://example.com/sample' \
  -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8' \
  -H 'user-agent: Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) Chrome/144.0.0.0 Safari/537.36'
EOF
# ==============================================================================

show_help() {
    echo "Usage: ./wasps.sh [MODE] [OPTIONS]"
    echo ""
    echo "Modes (Required):"
    echo "  -p, --parse [FILE]     Parse HTML and generate Markdown"
    echo "  -d, --download [FILE]  Read Markdown and download PDFs"
    echo "  -a, --all [FILE]       Run parse, then immediately download"
    echo "  -t, --text [DIR]       Convert downloaded PDFs to TXT"
    echo "  -s, --search [PAGES]   Search PDFs by minimum page count"
    echo ""
    echo "I/O & Parser Options (Optional):"
    echo "  --parser MODE      Set parsing engine: 'generic' (default) or 'epub'"
    echo "  -i, --input        Specify input HTML file or URL (Default: $INPUT_FILE)"
    echo "  -m, --markdown     Specify output MD file (Default: $MD_FILE)"
    echo "  -w, --workdir      Specify download directory (Default: $DOWNLOAD_DIR)"
    echo "  -b, --base-url     Base URL for generic relative links (Default: $BASE_URL)"
    echo "  -n, --pages        Minimum pages for search mode (Default: $MIN_PAGES)"
    echo "  -v, --verbose      Enable verbose output for debugging downloads"
    echo ""
    echo "Download Options (Optional):"
    echo "  --referer URL      Referer header (Default: base URL)"
    echo "  --secure           Verify TLS certificates (Default: off / curl -k)"
    echo "  --no-validate      Keep downloads even if they look like HTML pages"
    echo ""
    echo "Workflow Pipeline:"
    echo "  [ HTML ] --(-p)--> [ Markdown ] --(-d)--> [ PDFs ] --(-t)--> [ TXT ]"
    echo "                                                 |-----(-s)--> [ Search Results ]"
    echo "  "
    echo "  [ HTML ] ------------- (-a) ------------> [ PDFs ]"
    exit 1
}

# ==============================================================================
# HELPERS
# ==============================================================================

# Decode %XX sequences (e.g. My%20File -> My File)
urldecode() {
    local s="$1"
    printf '%b' "${s//%/\\x}"
}

# Pull the quoted value following a curl flag out of one line of the pasted cURL.
#   curl_opt_val "-H" "  -H 'accept: */*' \"
curl_opt_val() {
    local v
    v=$(grep -oP -- "(?:^|\s)$1 \K\\\$?(?:'[^']*'|\"[^\"]*\")" <<< "$2" | head -1)
    v="${v#\$}"
    [[ -n "$v" ]] && printf '%s' "${v:1:${#v}-2}"
}

# Build CURL_ARGS (global array) from the CHROME_CURL heredoc.
build_curl_args() {
    CURL_ARGS=("-L" "--compressed" "--retry" "2" "--connect-timeout" "30")
    if [[ $INSECURE -eq 1 ]]; then CURL_ARGS+=("-k"); fi
    if [[ $VERBOSE -eq 1 ]]; then CURL_ARGS+=("-v"); fi

    local line val hl have_ref=0 n=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*# ]]; then continue; fi

        val=$(curl_opt_val "-H" "$line")
        if [[ -n "$val" ]]; then
            hl="${val%%:*}"; hl="${hl,,}"
            # Skipped on purpose:
            #  - if-modified-since / if-none-match / if-range / range -> server answers 304/206 = empty or partial file
            #  - accept-encoding -> without --compressed, curl saves still-compressed bytes (corrupt PDF)
            case "$hl" in
                ""|:*|if-modified-since|if-none-match|if-range|range|accept-encoding|content-length|host|connection) ;;
                *)
                    if [[ "$hl" == "referer" ]]; then have_ref=1; fi
                    CURL_ARGS+=("-H" "$val"); n=$((n + 1)) ;;
            esac
        fi

        val=$(curl_opt_val "-b" "$line")
        if [[ -n "$val" ]]; then CURL_ARGS+=("-b" "$val"); n=$((n + 1)); fi

        val=$(curl_opt_val "-A" "$line")
        if [[ -n "$val" ]]; then CURL_ARGS+=("-A" "$val"); n=$((n + 1)); fi

        val=$(curl_opt_val "-e" "$line")
        if [[ -n "$val" ]]; then CURL_ARGS+=("-e" "$val"); have_ref=1; n=$((n + 1)); fi
    done <<< "$CHROME_CURL"

    if [[ -n "$REFERER" ]]; then
        CURL_ARGS+=("-e" "$REFERER;auto")
    elif [[ $have_ref -eq 0 && -n "$BASE_URL" ]]; then
        CURL_ARGS+=("-e" "$BASE_URL;auto")
    fi

    echo "curl config: $n header/cookie option(s) loaded from CHROME_CURL" >&2
}

# Is this file plausibly the real thing, and not an HTML login/error page?
is_valid_download() {   # is_valid_download FILE EXT
    local f="$1" ext="${2,,}"
    [[ -s "$f" ]] || return 1
    [[ $VALIDATE -eq 1 ]] || return 0
    case "$ext" in
        pdf)                head -c 1024 "$f" | grep -aq '%PDF-' ;;
        docx|xlsx|pptx|zip) [[ "$(head -c 2 "$f")" == "PK" ]] ;;
        *)                  ! head -c 1024 "$f" | grep -aiqE '<(!doctype html|html)' ;;
    esac
}

# Remove duplicate URLs and give same-named files different URLs a _2, _3 suffix.
dedupe_md() {
    local tmp="${MD_FILE}.tmp" line rest name url base ext n
    declare -A seen_url seen_name
    : > "$tmp"
    while IFS= read -r line; do
        if [[ "$line" != '* ['* ]]; then echo "$line" >> "$tmp"; continue; fi
        rest="${line#\* \[}"; name="${rest%%\](*}"; url="${rest#*\](}"; url="${url%)}"
        if [[ -n "${seen_url[$url]:-}" ]]; then continue; fi
        seen_url[$url]=1
        if [[ -n "${seen_name[$name]:-}" ]]; then
            base="${name%.*}"; ext="${name##*.}"; n=2
            while [[ -n "${seen_name[${base}_${n}.${ext}]:-}" ]]; do n=$((n + 1)); done
            name="${base}_${n}.${ext}"
        fi
        seen_name[$name]=1
        echo "* [${name}](${url})" >> "$tmp"
    done < "$MD_FILE"
    mv "$tmp" "$MD_FILE"
}

# ==============================================================================
# PARSE
# ==============================================================================

parse_html() {
    # If the input is a URL, fetch it first using the same headers/cookies as downloads
    if [[ "$INPUT_FILE" =~ ^https?:// ]]; then
        local page_url="$INPUT_FILE"
        if [[ $BASE_URL_SET -eq 0 ]]; then BASE_URL="$page_url"; fi
        build_curl_args
        INPUT_FILE="${MD_FILE%.*}.source.html"
        echo "Fetching page: $page_url"
        if ! curl "${CURL_ARGS[@]}" -sS -f -o "$INPUT_FILE" "$page_url" < /dev/null; then
            echo "Error: could not fetch $page_url (login needed? refresh CHROME_CURL cookies)."
            exit 1
        fi
        echo "Saved page source to $INPUT_FILE ($(wc -c < "$INPUT_FILE") bytes)"
    fi

    echo "Parsing $INPUT_FILE using [$PARSER_MODE] engine..."
    
    if [[ ! -f "$INPUT_FILE" ]]; then
        echo "Error: Input file '$INPUT_FILE' not found."
        exit 1
    fi

    echo "# WASPS Extracted Documents ($PARSER_MODE mode)" > "$MD_FILE"
    echo "Generated on: $(date)" >> "$MD_FILE"
    echo "" >> "$MD_FILE"

    case "$PARSER_MODE" in

        # ----------------------------------------------------------------------
        # ENGINE: GENERIC (Regex match against allowed extensions)
        # ----------------------------------------------------------------------
        generic)
            DOMAIN_ROOT=$(echo "$BASE_URL" | grep -oP '^https?://[^/]+')
            [[ -z "$DOMAIN_ROOT" ]] && DOMAIN_ROOT="$BASE_URL"
            SCHEME="${DOMAIN_ROOT%%:*}"

            # Directory used for page-relative links (e.g. "files/a.pdf")
            BASE_DIR="${BASE_URL%%[?#]*}"
            if [[ "$BASE_DIR" == "$DOMAIN_ROOT" ]]; then
                BASE_DIR="${DOMAIN_ROOT}/"
            elif [[ "$BASE_DIR" != */ ]]; then
                BASE_DIR="${BASE_DIR%/*}/"
            fi

            # Extract href/src values ending in allowed extensions, excluding preview actions
            grep -ioP "(?:href|src)\s*=\s*[\"']\K[^\"']+" "$INPUT_FILE" | \
            sed 's/&amp;/\&/g; s/&#38;/\&/g' | \
            grep -iE '\.('"${ALLOWED_EXT}"')(\?.*)?(#.*)?$' | \
            grep -vE '\.action(\?|$)' | \
            tr -d '\r' | sort -u | while read -r url; do
                [[ -z "$url" ]] && continue
                
                # Strip query parameters specifically for extracting clean filename/extension
                base_url=$(echo "$url" | sed 's/\?.*//; s/#.*//')
                
                raw_name=$(basename "$base_url")
                ext="${raw_name##*.}"
                ext="${ext,,}"
                raw_name_no_ext="${raw_name%.*}"
                
                # Clean up filename (decode %20 etc. first)
                clean_name=$(urldecode "$raw_name_no_ext" | sed 's/[[:space:]]/_/g' | sed 's/[^a-zA-Z0-9._-]//g')
                [[ -z "$clean_name" ]] && continue

                # Build full URL
                if [[ "$url" == //* ]]; then
                    full_url="${SCHEME}:${url}"
                elif [[ "$url" == /* ]]; then
                    full_url="${DOMAIN_ROOT%/}${url}"
                elif [[ "$url" != http* ]]; then
                    full_url="${BASE_DIR}${url#./}"
                else
                    full_url="$url"
                fi
                
                # Sanitize spaces and parentheses in URLs (they would break the Markdown link)
                full_url=$(echo "$full_url" | sed 's/ /%20/g; s/(/%28/g; s/)/%29/g')
                
                echo "* [${clean_name}.${ext}](${full_url})"
            done >> "$MD_FILE"
            ;;

        # ----------------------------------------------------------------------
        # ENGINE: YOUR CUSTOM PARSER (Template for future use)
        # ----------------------------------------------------------------------
        custom_example)
            echo "Implement your custom extraction logic here."
            echo "Ensure output lines follow: * [Clean_Filename.ext](https://url...)" >> "$MD_FILE"
            ;;

        *)
            echo "Error: Unknown parser mode '$PARSER_MODE'"
            exit 1
            ;;
    esac

    dedupe_md

    count=$(grep -c "^\*" "$MD_FILE")
    echo "Extraction complete. Found $count documents."
    if [[ "$count" -eq 0 ]]; then
        echo "Nothing found. If the page needs a login, check that $INPUT_FILE isn't just a login page."
    fi
    return 0
}

# ==============================================================================
# DOWNLOAD
# ==============================================================================

download_files() {
    echo "Starting download process from $MD_FILE..."
    
    if [[ ! -f "$MD_FILE" ]]; then
        echo "Error: $MD_FILE not found. Run parse mode (-p) first."
        exit 1
    fi

    mkdir -p "$DOWNLOAD_DIR"
    
    # Headers/cookies from the CHROME_CURL heredoc at the top of this file
    build_curl_args

    PROGRESS=("-#")
    if [[ $VERBOSE -eq 1 ]]; then PROGRESS=(); fi

    faillog="$DOWNLOAD_DIR/failed.log"
    : > "$faillog"
    ok=0; skip=0; fail=0

    # Download Loop mapping to uniform Markdown format (fd 3 so curl can never eat the list)
    while IFS= read -r line <&3; do
        url=$(echo "$line" | grep -oP '\]\(\K[^\)]+')
        filename=$(echo "$line" | grep -oP '\[\K[^\]]+')

        if [[ -n "$url" && -n "$filename" ]]; then
            target_path="$DOWNLOAD_DIR/$filename"
            part_path="$target_path.part"
            ext="${filename##*.}"
            
            if [[ -s "$target_path" ]]; then
                if is_valid_download "$target_path" "$ext"; then
                    echo "Skipping: $filename (Already exists)"
                    skip=$((skip + 1))
                    continue
                fi
                echo "Re-downloading: $filename (existing file is not a valid $ext)"
                rm -f "$target_path"
            fi

            echo "Downloading: $filename"
            code=$(curl "${CURL_ARGS[@]}" "${PROGRESS[@]}" -f -o "$part_path" -w '%{http_code}' "$url" < /dev/null)
            rc=$?

            if [[ $rc -eq 0 ]] && is_valid_download "$part_path" "$ext"; then
                mv "$part_path" "$target_path"
                ok=$((ok + 1))
            else
                if [[ $rc -ne 0 ]]; then
                    reason="curl exit $rc, HTTP $code"
                    rm -f "$part_path"
                else
                    reason="HTTP $code but content is not a real $ext (login/error page?) - kept as $filename.rejected"
                    mv "$part_path" "$target_path.rejected"
                fi
                echo "  FAILED: $reason"
                echo "$filename  $url  $reason" >> "$faillog"
                fail=$((fail + 1))
            fi
            sleep "$DELAY"
        fi
    done 3< <(grep "^\*" "$MD_FILE")

    echo "All downloads complete. downloaded=$ok skipped=$skip failed=$fail"
    if [[ $fail -gt 0 ]]; then
        echo "See $faillog. If these are login pages, refresh the cookies in CHROME_CURL."
    else
        rm -f "$faillog"
    fi
}

convert_pdfs() {
    echo "Converting PDFs to text in $DOWNLOAD_DIR..."
    if ! command -v pdftotext &> /dev/null; then
        echo "Error: pdftotext is not installed. (sudo apt install poppler-utils)"
        exit 1
    fi

    for pdf in "$DOWNLOAD_DIR"/*.pdf; do
        [[ -e "$pdf" ]] || { echo "No PDFs found in $DOWNLOAD_DIR"; return 0; }
        
        txt_file="${pdf%.pdf}.txt"
        if [[ -s "$txt_file" ]]; then
            echo "Skipping: $(basename "$txt_file") (Already exists)"
        else
            echo "Converting: $(basename "$pdf")"
            pdftotext "$pdf" "$txt_file"
        fi
    done
}

find_large_pdfs() {
    echo "Searching for PDFs with >= $MIN_PAGES pages in: $DOWNLOAD_DIR..."
    if ! command -v pdfinfo &> /dev/null; then
        echo "Error: pdfinfo is not installed. (sudo apt install poppler-utils)"
        exit 1
    fi

    found=0
    for pdf in "$DOWNLOAD_DIR"/*.pdf; do
        [[ -e "$pdf" ]] || { echo "No PDFs found in $DOWNLOAD_DIR"; return 0; }
        
        pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/ {print $2}')
        
        if [[ -n "$pages" && "$pages" -ge "$MIN_PAGES" ]]; then
            echo -e "Pages: $pages\tFile: $(basename "$pdf")"
            found=$((found + 1))
        fi
    done

    echo "Found $found document(s) matching criteria."
}

# ==============================================================================
# ARGUMENT ROUTER
# ==============================================================================

# True if the next argument exists and is a value (not another flag)
opt_arg() { [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; }

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--parse) MODE="parse"; if opt_arg "$@"; then INPUT_FILE="$2"; shift; fi; shift ;;
        -d|--download) MODE="download"; if opt_arg "$@"; then MD_FILE="$2"; shift; fi; shift ;;
        -a|--all) MODE="all"; if opt_arg "$@"; then INPUT_FILE="$2"; shift; fi; shift ;;
        -t|--text) MODE="text"; if opt_arg "$@"; then DOWNLOAD_DIR="$2"; shift; fi; shift ;;
        -s|--search) MODE="search"; if opt_arg "$@"; then MIN_PAGES="$2"; shift; fi; shift ;;
        --parser) PARSER_MODE="$2"; shift 2 ;;
        -i|--input) INPUT_FILE="$2"; shift 2 ;;
        -m|--markdown) MD_FILE="$2"; shift 2 ;;
        -w|--workdir) DOWNLOAD_DIR="$2"; shift 2 ;;
        -b|--base-url) BASE_URL="$2"; BASE_URL_SET=1; shift 2 ;;
        -n|--pages) MIN_PAGES="$2"; shift 2 ;;
        --referer) REFERER="$2"; shift 2 ;;
        --secure) INSECURE=0; shift ;;
        --no-validate) VALIDATE=0; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) show_help ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
done

case "$MODE" in
    parse) parse_html ;;
    download) download_files ;;
    all) parse_html; download_files ;;
    text) convert_pdfs ;;
    search) find_large_pdfs ;;
    *) echo "Error: You must specify a mode (-p, -d, -a, -t, or -s)."; show_help ;;
esac
