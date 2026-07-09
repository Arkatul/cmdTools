# Bash Passphrase Generator

This folder contains a Bash script (`genPassphrase.sh`) used to generate random passphrases, built on a local word dictionary — no network access required.

## Installation

Run the installer (requires root, since it writes under `/usr/local`):

```bash
sudo ./install.sh
```

This installs:

- `/usr/local/bin/genpassphrase` – the executable (already in `PATH` on virtually every Linux system).
- `/usr/local/share/genpassphrase/wordlist.txt` – the word dictionary.

Once installed, run it from anywhere:

```bash
genpassphrase [options]
```

You can also run `genPassphrase.sh` directly from this folder without installing — it falls back to the `wordlist.txt` sitting next to it.

## Usage

```bash
./genPassphrase.sh [options]
# or, once installed:
genpassphrase [options]
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

### Validation

- `--num-words`, `--num-specials`, `--num-digits` must be non-negative integers, and `--num-words` cannot exceed the wordlist size (7776 words).
- `--case-profile` must be an integer from `1` to `5`.
- `--allowed-specials` and `--separators` must not be empty strings.

Invalid values are rejected immediately with a clear error message.

## Dependencies

- `shuf` (part of GNU coreutils, present on virtually all Linux systems) – picks random words from the local wordlist.

## Wordlist

`wordlist.txt` is the [EFF Large Wordlist](https://www.eff.org/dice) (7776 words), the standard word list used for Diceware-style passphrases: distinct words, no easily-confused pairs, no proper nouns.

The script looks for the wordlist in this order:

1. `$GENPASSPHRASE_WORDLIST` environment variable, if set (points to any wordlist file, one word per line).
2. `/usr/local/share/genpassphrase/wordlist.txt` (the installed location).
3. `wordlist.txt` next to `genPassphrase.sh` (dev mode, no install needed).

## Description

The script picks random words from the local wordlist, applies a case profile, and combines them with random digits and special characters to build a passphrase. Prefix and suffix special characters are mirrored so the passphrase begins and ends symmetrically.
