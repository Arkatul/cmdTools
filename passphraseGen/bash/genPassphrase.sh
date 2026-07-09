#!/bin/bash

set -euo pipefail

command -v shuf >/dev/null 2>&1 || { echo "shuf is required (coreutils)"; exit 1; }

# ===== CONFIGURABLE PARAMETERS =====
NUM_WORDS=4
NUM_SPECIALS=2
NUM_DIGITS=2
ALLOWED_SPECIALS='!@#%&*'
SEPARATORS='-_:.'
CASE_PROFILE=3

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -n, --num-words NUM        Number of words (default: $NUM_WORDS)
  -s, --num-specials NUM     Number of special characters (default: $NUM_SPECIALS)
  -d, --num-digits NUM       Number of digits (default: $NUM_DIGITS)
  -a, --allowed-specials SET Allowed special characters (default: "$ALLOWED_SPECIALS")
  -e, --separators SET       Possible word separators (default: "$SEPARATORS")
  -c, --case-profile NUM     Case profile [1-5] (default: $CASE_PROFILE)
                              1: all lowercase
                              2: all uppercase
                              3: random case per word
                              4: one random letter uppercase per word
                              5: random case per letter
  -h, --help                 Display this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -n|--num-words)
            NUM_WORDS="$2"
            shift 2
            ;;
        -s|--num-specials)
            NUM_SPECIALS="$2"
            shift 2
            ;;
        -d|--num-digits)
            NUM_DIGITS="$2"
            shift 2
            ;;
        -a|--allowed-specials)
            ALLOWED_SPECIALS="$2"
            shift 2
            ;;
        -e|--separators)
            SEPARATORS="$2"
            shift 2
            ;;
        -c|--case-profile)
            CASE_PROFILE="$2"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ===== VALIDATE PARAMETERS =====
for pair in "num-words:$NUM_WORDS" "num-specials:$NUM_SPECIALS" "num-digits:$NUM_DIGITS"; do
    name="${pair%%:*}"
    value="${pair#*:}"
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: --$name must be a non-negative integer, got '$value'" >&2
        exit 1
    fi
done

if [[ ! "$CASE_PROFILE" =~ ^[1-5]$ ]]; then
    echo "Error: --case-profile must be an integer 1-5, got '$CASE_PROFILE'" >&2
    exit 1
fi

if [[ -z "$ALLOWED_SPECIALS" ]]; then
    echo "Error: --allowed-specials must not be empty" >&2
    exit 1
fi

if [[ -z "$SEPARATORS" ]]; then
    echo "Error: --separators must not be empty" >&2
    exit 1
fi

# ===== FUNCTION: Get random characters from a set =====
rand_chars() {
    local set="$1"
    local count="$2"
    local output=""
    if (( ${#set} == 0 )); then
        echo "rand_chars: empty character set" >&2
        exit 1
    fi
    for ((i = 0; i < count; i++)); do
        rand_index=$(( RANDOM % ${#set} ))
        output+="${set:$rand_index:1}"
    done
    echo "$output"
}

# ===== LOCATE WORDLIST =====
# Order: explicit override, system install location, next to this script (dev mode).
if [[ -n "${GENPASSPHRASE_WORDLIST:-}" ]]; then
    WORDLIST_FILE="$GENPASSPHRASE_WORDLIST"
elif [[ -f "/usr/local/share/genpassphrase/wordlist.txt" ]]; then
    WORDLIST_FILE="/usr/local/share/genpassphrase/wordlist.txt"
else
    WORDLIST_FILE="$(dirname "$(readlink -f "$0")")/wordlist.txt"
fi

if [[ ! -r "$WORDLIST_FILE" ]]; then
    echo "Error: wordlist not found or not readable at '$WORDLIST_FILE'" >&2
    echo "Run install.sh, or set GENPASSPHRASE_WORDLIST to a valid wordlist file." >&2
    exit 1
fi

# ===== PICK RANDOM WORDS FROM LOCAL WORDLIST =====
WORDLIST_LINES=$(wc -l < "$WORDLIST_FILE")
if (( NUM_WORDS > WORDLIST_LINES )); then
    echo "Error: --num-words ($NUM_WORDS) exceeds the wordlist size ($WORDLIST_LINES words)" >&2
    exit 1
fi

readarray -t WORD_ARRAY < <(shuf -n "$NUM_WORDS" "$WORDLIST_FILE")

apply_case_profile() {
    local i j word len index out char
    case "$CASE_PROFILE" in
        1)
            for ((i=0; i<${#WORD_ARRAY[@]}; i++)); do
                WORD_ARRAY[i]="${WORD_ARRAY[i],,}"
            done
            ;;
        2)
            for ((i=0; i<${#WORD_ARRAY[@]}; i++)); do
                WORD_ARRAY[i]="${WORD_ARRAY[i]^^}"
            done
            ;;
        3)
            for ((i=0; i<${#WORD_ARRAY[@]}; i++)); do
                if (( RANDOM % 2 )); then
                    WORD_ARRAY[i]="${WORD_ARRAY[i]^^}"
                else
                    WORD_ARRAY[i]="${WORD_ARRAY[i],,}"
                fi
            done
            ;;
        4)
            for ((i=0; i<${#WORD_ARRAY[@]}; i++)); do
                word="${WORD_ARRAY[i],,}"
                len=${#word}
                if (( len == 0 )); then
                    continue
                fi
                index=$(( RANDOM % len ))
                char="${word:index:1}"
                WORD_ARRAY[i]="${word:0:index}${char^^}${word:index+1}"
            done
            ;;
        5)
            for ((i=0; i<${#WORD_ARRAY[@]}; i++)); do
                word="${WORD_ARRAY[i]}"
                out=""
                for ((j=0; j<${#word}; j++)); do
                    char="${word:j:1}"
                    if (( RANDOM % 2 )); then
                        out+="${char^^}"
                    else
                        out+="${char,,}"
                    fi
                done
                WORD_ARRAY[i]="$out"
            done
            ;;
        *)
            echo "Error: invalid case profile '$CASE_PROFILE' (must be 1-5)" >&2
            exit 1
            ;;
    esac
}

apply_case_profile

# ===== CHOOSE RANDOM SEPARATOR =====
SEP_INDEX=$(( RANDOM % ${#SEPARATORS} ))
SEP="${SEPARATORS:$SEP_INDEX:1}"

# ===== JOIN WORDS WITH SEPARATOR =====
JOINED_WORDS=$(IFS="$SEP"; echo "${WORD_ARRAY[*]}")

# ===== BUILD PASSPHRASE =====
PREFIX_SPECIALS=$(rand_chars "$ALLOWED_SPECIALS" "$NUM_SPECIALS")
SUFFIX_SPECIALS=$(echo "$PREFIX_SPECIALS" | rev)
PREFIX_DIGITS=$(rand_chars "0123456789" "$NUM_DIGITS")
SUFFIX_DIGITS=$(rand_chars "0123456789" "$NUM_DIGITS")

PASSPHRASE="${PREFIX_SPECIALS}${PREFIX_DIGITS}${SEP}${JOINED_WORDS}${SEP}${SUFFIX_DIGITS}${SUFFIX_SPECIALS}"

# ===== OUTPUT =====
echo "Generated passphrase:"
echo "$PASSPHRASE"
