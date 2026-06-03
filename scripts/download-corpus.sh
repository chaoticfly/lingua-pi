#!/usr/bin/env bash
# LinguaPi Corpus Downloader
#
# Downloads public-domain texts for offline use:
#   - Project Gutenberg  (Latin-script languages: es, de, pt, it, fr, ja)
#   - Wikisource         (Indian-script languages: hi, kn, te)
#
# The LinguaPi server automatically prefers local corpus files over live
# internet fetches, so running this script makes generation faster, more
# varied, and fully offline for the "Novels & Literature" category.
#
# Usage:
#   bash scripts/download-corpus.sh                        # all languages
#   bash scripts/download-corpus.sh Spanish German         # specific languages
#   bash scripts/download-corpus.sh --force Spanish        # re-download
#   BOOKS_PER_LANG=50 bash scripts/download-corpus.sh      # more books
#
# Options (env vars):
#   BOOKS_PER_LANG   Books per language (default: 10)
#   CORPUS_DIR       Override corpus directory (default: ~/.linguapi/corpus)
#   DELAY            Seconds between downloads (default: 0.5)
#
# Requires: curl, python3

set -euo pipefail

CORPUS_DIR="${CORPUS_DIR:-${HOME}/.linguapi/corpus}"
BOOKS_PER_LANG="${BOOKS_PER_LANG:-10}"
DELAY="${DELAY:-0.5}"
GUTENDEX="https://gutendex.com/books"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
info()    { echo -e "${CYAN}>>  ${NC}$*"; }
success() { echo -e "${GREEN}OK  ${NC}$*"; }
warn()    { echo -e "${YELLOW}!!  ${NC}$*"; }
die()     { echo -e "${RED}ERR ${NC}$*" >&2; exit 1; }

# Language name -> ISO 639-1 code
declare -A LANG_CODES=(
    [Spanish]="es"   [German]="de"   [Portuguese]="pt"
    [Italian]="it"   [Kannada]="kn"  [Telugu]="te"
)

# Source routing: Gutenberg has poor coverage for Indian-script languages
declare -A LANG_SOURCE=(
    [Spanish]="gutenberg"   [German]="gutenberg"   [Portuguese]="gutenberg"
    [Italian]="gutenberg"   [Kannada]="wikisource"  [Telugu]="wikisource"
)

check_deps() {
    command -v curl    >/dev/null 2>&1 || die "'curl' is required."
    command -v python3 >/dev/null 2>&1 || die "'python3' is required."
}

# ── Project Gutenberg ─────────────────────────────────────────────────────────

parse_gutendex_page() {
    python3 - "$1" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for book in data.get("results", []):
    book_id = book.get("id", 0)
    title   = book.get("title", "Unknown").replace("\t", " ")
    formats = book.get("formats", {})
    url = ""
    for k, v in sorted(formats.items()):
        if k.startswith("text/plain") and not v.endswith(".zip"):
            url = v
            break
    if url:
        print(f"{book_id}\t{url}\t{title}")
PYEOF
}

download_gutenberg_language() {
    local lang_name="$1" lang_code="${LANG_CODES[$1]}"
    local lang_dir="${CORPUS_DIR}/${lang_code}"
    mkdir -p "$lang_dir"

    local existing; existing=$(find "$lang_dir" -maxdepth 1 -name "pg*.txt" | wc -l | tr -d ' ')
    local need=$(( BOOKS_PER_LANG - existing ))
    if [ "$need" -le 0 ]; then
        success "${lang_name}: already has ${existing} Gutenberg books."; return
    fi

    echo -e "\n${BOLD}${lang_name}${NC} ${DIM}(${lang_code} — Gutenberg)${NC}"

    # Get total pages from gutendex
    local tmp; tmp=$(mktemp)
    curl -fsSL --max-time 15 "${GUTENDEX}/?languages=${lang_code}&mime_type=text%2Fplain&page=1" \
        -o "$tmp" 2>/dev/null || { warn "Cannot reach gutendex."; rm -f "$tmp"; return; }

    local total_pages
    total_pages=$(python3 -c "
import json,sys,math
data=json.load(open('$tmp'))
print(math.ceil(data.get('count',0)/32))")

    if [ "$total_pages" -eq 0 ]; then
        warn "gutendex returned 0 books for ${lang_name} — skipping."; rm -f "$tmp"; return
    fi

    local downloaded=0 skipped=0 failed=0 page=1
    while [ $downloaded -lt $need ] && [ $page -le "$total_pages" ] && [ $page -le 30 ]; do
        [ $page -gt 1 ] && curl -fsSL --max-time 15 \
            "${GUTENDEX}/?languages=${lang_code}&mime_type=text%2Fplain&page=${page}" \
            -o "$tmp" 2>/dev/null || { ((page++)); continue; }

        while IFS=$'\t' read -r book_id url title && [ $downloaded -lt $need ]; do
            local fp="${lang_dir}/pg${book_id}.txt"
            if [ -f "$fp" ] && [ -s "$fp" ]; then ((skipped++)) || true; continue; fi

            printf "  ${DIM}[%d/%d]${NC} %.55s ... " "$(( existing+downloaded+1 ))" "$BOOKS_PER_LANG" "$title"
            if curl -fsSL --max-time 60 --retry 2 --retry-delay 2 "$url" -o "$fp" 2>/dev/null \
                    && [ -s "$fp" ]; then
                printf "${GREEN}OK${NC} %dKB\n" "$(( $(wc -c <"$fp") / 1024 ))"
                ((downloaded++)) || true; sleep "$DELAY"
            else
                rm -f "$fp"; printf "${RED}fail${NC}\n"; ((failed++)) || true
            fi
        done < <(parse_gutendex_page "$tmp")
        ((page++)) || true
    done
    rm -f "$tmp"

    local total_now; total_now=$(find "$lang_dir" -maxdepth 1 -name "pg*.txt" | wc -l | tr -d ' ')
    echo -e "  ${downloaded} downloaded, ${skipped} skipped, ${failed} failed -> ${total_now} total"
}

# ── Wikisource ────────────────────────────────────────────────────────────────

# Strip basic wiki markup to plain text
strip_wikitext() {
    python3 <<'PYEOF'
import sys, re
text = sys.stdin.read()
text = re.sub(r'<ref[^>]*>.*?</ref>', '', text, flags=re.S)   # references
text = re.sub(r'\{\{[^}]*\}\}', '', text)                       # templates
text = re.sub(r'\[\[(?:File|Image|Category|चित्र|ಚಿತ್ರ|దస్త్రం):[^\]]*\]\]', '', text, flags=re.I)
text = re.sub(r'\[\[(?:[^|\]]*\|)?([^\]]+)\]\]', r'\1', text)  # [[link|display]] -> display
text = re.sub(r'\[https?://\S+ ([^\]]+)\]', r'\1', text)        # [url display]
text = re.sub(r'\[https?://\S+\]', '', text)                    # bare urls
text = re.sub(r'<[^>]+>', '', text)                             # HTML tags
text = re.sub(r'={2,}[^=]+=+', '\n', text)                     # headings
text = re.sub(r"'{2,}", '', text)                               # bold/italic
text = re.sub(r'^\*+\s*', '', text, flags=re.M)                 # list bullets
text = re.sub(r'^\|.*$', '', text, flags=re.M)                  # table rows
text = re.sub(r'\n{3,}', '\n\n', text.strip())
print(text)
PYEOF
}

download_wikisource_language() {
    local lang_name="$1" lang_code="${LANG_CODES[$1]}"
    local lang_dir="${CORPUS_DIR}/${lang_code}"
    local api="https://${lang_code}.wikisource.org/w/api.php"
    mkdir -p "$lang_dir"

    local existing; existing=$(find "$lang_dir" -maxdepth 1 -name "ws_*.txt" | wc -l | tr -d ' ')
    local need=$(( BOOKS_PER_LANG - existing ))
    if [ "$need" -le 0 ]; then
        success "${lang_name}: already has ${existing} Wikisource texts."; return
    fi

    echo -e "\n${BOLD}${lang_name}${NC} ${DIM}(${lang_code} — Wikisource)${NC}"

    local downloaded=0 attempts=0 max_attempts=$(( need * 8 ))
    local tmp; tmp=$(mktemp)

    while [ $downloaded -lt $need ] && [ $attempts -lt $max_attempts ]; do
        # Get a batch of random page IDs
        curl -fsSL --max-time 15 \
            "${api}?action=query&list=random&rnnamespace=0&rnlimit=20&format=json" \
            -o "$tmp" 2>/dev/null || { ((attempts++)); continue; }

        # Extract page IDs and titles
        while IFS=$'\t' read -r page_id page_title && [ $downloaded -lt $need ]; do
            ((attempts++)) || true
            [ -z "$page_id" ] && continue

            local safe; safe=$(echo "$page_title" | tr '/' '_' | tr ' ' '_' | \
                               tr -d '[]{}|"<>*?:\\')
            local fp="${lang_dir}/ws_${safe}.txt"
            [ -f "$fp" ] && [ -s "$fp" ] && continue

            printf "  ${DIM}[%d/%d]${NC} %.55s ... " "$(( existing+downloaded+1 ))" "$BOOKS_PER_LANG" "$page_title"

            # Fetch raw wikitext
            local raw_url="${api}?action=query&pageids=${page_id}&prop=revisions&rvprop=content&rvslots=main&format=json"
            local content
            content=$(curl -fsSL --max-time 15 "$raw_url" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
pages = data.get('query', {}).get('pages', {})
for p in pages.values():
    slots = p.get('revisions', [{}])[0].get('slots', {}).get('main', {})
    text = slots.get('*', '')
    if text: print(text)
    break
" 2>/dev/null | strip_wikitext)

            local char_count=${#content}
            if [ "$char_count" -gt 300 ]; then
                echo "$content" > "$fp"
                printf "${GREEN}OK${NC} %dchars\n" "$char_count"
                ((downloaded++)) || true
                sleep "$DELAY"
            else
                printf "${DIM}skip (too short)${NC}\n"
            fi
        done < <(python3 -c "
import json, sys
data = json.load(open('$tmp'))
for p in data.get('query', {}).get('random', []):
    print(str(p['id']) + '\t' + p['title'])
" 2>/dev/null)
    done
    rm -f "$tmp"

    local total_now; total_now=$(find "$lang_dir" -maxdepth 1 -name "ws_*.txt" | wc -l | tr -d ' ')
    echo -e "  ${downloaded} downloaded (${attempts} attempts) -> ${total_now} total"
}

# ── Argument parsing ──────────────────────────────────────────────────────────

FORCE=false; POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        --help|-h)
            echo "Usage: $0 [--force] [LANGUAGE...]"
            echo "Languages: ${!LANG_CODES[*]}"
            echo "Env vars:  BOOKS_PER_LANG (default 10), CORPUS_DIR, DELAY"
            exit 0 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    check_deps

    local langs_to_run=()
    if [ $# -gt 0 ]; then
        for name in "$@"; do
            if [[ -v LANG_CODES[$name] ]]; then langs_to_run+=("$name")
            else warn "Unknown language '${name}'. Supported: ${!LANG_CODES[*]}"; fi
        done
    else
        langs_to_run=("${!LANG_CODES[@]}")
    fi
    [ ${#langs_to_run[@]} -eq 0 ] && die "No valid languages specified."

    echo -e "${BOLD}LinguaPi Corpus Downloader${NC}"
    echo "  Corpus dir    : ${CORPUS_DIR}"
    echo "  Books/language: ${BOOKS_PER_LANG}"
    echo "  Languages     : ${langs_to_run[*]}"
    echo ""
    echo "  Sources:"
    for lang in "${langs_to_run[@]}"; do
        printf "    %-14s %s\n" "$lang" "${LANG_SOURCE[$lang]}"
    done

    if $FORCE; then
        warn "--force: removing existing files."
        for name in "${langs_to_run[@]}"; do
            code="${LANG_CODES[$name]}"
            rm -f "${CORPUS_DIR}/${code}"/pg*.txt "${CORPUS_DIR}/${code}"/ws_*.txt 2>/dev/null || true
        done
    fi

    mkdir -p "$CORPUS_DIR"
    for lang in "${langs_to_run[@]}"; do
        source="${LANG_SOURCE[$lang]}"
        if [ "$source" = "wikisource" ]; then
            download_wikisource_language "$lang"
        else
            download_gutenberg_language "$lang"
        fi
    done

    echo ""
    success "Corpus sync complete. Restart LinguaPi to use local files."
    echo -e "  Location: ${DIM}${CORPUS_DIR}${NC}"
    echo ""
    echo "Book counts:"
    for lang in "${langs_to_run[@]}"; do
        code="${LANG_CODES[$lang]}"
        dir="${CORPUS_DIR}/${code}"
        count=$(find "$dir" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
        src="${LANG_SOURCE[$lang]}"
        printf "  %-14s %s texts  (%s)\n" "${lang}:" "$count" "$src"
    done
}

main "$@"
