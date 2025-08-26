# Bash Passphrase Generator

This folder contains a Bash script (`genPassphrase.sh`) used to generate random passphrases.

## Usage

Run the script directly:

```bash
./genPassphrase.sh [options]
```

Use `-h` or `--help` to see all available options.

## Options

The script accepts several parameters to customize the generated passphrase:

- `-n, --num-words NUM` – number of random words to include (default: `4`).
- `-s, --num-specials NUM` – number of special characters used at the prefix and suffix (default: `2`).
- `-d, --num-digits NUM` – number of digits placed before and after the words (default: `2`).
- `-a, --allowed-specials SET` – characters that may appear as special characters (default: `!@#%&*`).
- `-e, --separators SET` – possible separators between words; one character is chosen at random (default: `-_:.`).
- `-c, --case-profile NUM` – choose a case transformation profile (default: `3`):
  1. all lowercase
  2. all uppercase
  3. random case per word
  4. one random letter uppercase per word
  5. random case per letter

## Dependencies

- `curl` – used to download random words from the internet
- `jq` – parses the JSON response from the word API

## Description

The script fetches random words, applies a case profile, and combines them with random digits and special characters to build a passphrase. Prefix and suffix special characters are mirrored so the passphrase begins and ends symmetrically.
