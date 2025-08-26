# PowerShell Passphrase Generator

This folder contains a PowerShell script (`genPassphrase.ps1`) that generates random passphrases.

## Usage

Run the script with PowerShell:

```powershell
./genPassphrase.ps1 [-NumWords N] [-NumSpecials N] [-NumDigits N] [-AllowedSpecials SET] [-Separators SET] [-CaseProfile N]
```

Use `Get-Help ./genPassphrase.ps1 -Detailed` to see all available options.

## Options

- `-NumWords` – number of random words to include (default: `4`).
- `-NumSpecials` – number of special characters used at the prefix and suffix (default: `2`).
- `-NumDigits` – number of digits placed before and after the words (default: `2`).
- `-AllowedSpecials` – characters that may appear as special characters (default: `!@#%&*`).
- `-Separators` – possible separators between words; one character is chosen at random (default: `-_:.`).
- `-CaseProfile` – choose a case transformation profile (default: `3`):
  1. all lowercase
  2. all uppercase
  3. random case per word
  4. one random letter uppercase per word
  5. random case per letter

## Description

The script fetches random words from an online API, applies the selected case profile and mixes them with digits and special characters to build a symmetrical passphrase.
