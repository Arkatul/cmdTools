#!/usr/bin/env bash
#
# tests/test_menu.sh — Tests de select_from_menu (pim-activate.sh, goal 1).
#
# Deux étages :
#   1. Suite automatique : stdin alimenté par pipe, stderr redirigé. Couvre la
#      logique de sélection (flèches, numéro, annulation, cas limites). Tourne
#      partout, y compris sans terminal.
#   2. Suite interactive : stdin ET stderr sur le vrai terminal. Seule façon de
#      valider le redessin ANSI in-place — la branche `[[ -t 2 ]]` de
#      _menu_render est inatteignable derrière un pipe. Auto-skippée hors TTY.
#
# Usage :
#   bash tests/test_menu.sh          # auto + interactif (si terminal)
#   bash tests/test_menu.sh --auto   # suite automatique seule
#
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TEST_DIR}/../pim-activate.sh"

# shellcheck source=../pim-activate.sh
source "$TARGET"
# pim-activate.sh pose `set -euo pipefail` en se sourçant : on relâche -e, le
# harnais teste justement des retours non-zéro.
set +e

OPTS=("Contributor / sub-prod" "Owner / sub-dev" "Global Reader" "User Administrator")
fails=0
ONLY_AUTO=0
[[ "${1:-}" == "--auto" ]] && ONLY_AUTO=1

# ---------------------------------------------------------------------------
# 1. Suite automatique (pipe)
# ---------------------------------------------------------------------------

run_case() {
    local label="$1" keys="$2" exp_idx="$3" exp_rc="${4:-0}" got rc
    got="$(printf '%b' "$keys" | select_from_menu "Choisir un rôle :" "${OPTS[@]}" 2>/dev/null)"
    rc=$?
    if [[ "$got" == "$exp_idx" && $rc -eq $exp_rc ]]; then
        if [[ -n "$got" ]]; then
            printf 'PASS  %-42s -> index %s (%s)\n' "$label" "$got" "${OPTS[$got]}"
        else
            printf 'PASS  %-42s -> aucune selection, rc=%s\n' "$label" "$rc"
        fi
    else
        printf 'FAIL  %-42s -> attendu idx="%s" rc=%s, obtenu idx="%s" rc=%s\n' \
            "$label" "$exp_idx" "$exp_rc" "$got" "$rc"
        fails=$((fails + 1))
    fi
}

printf '=== Rendu hors TTY (4 entrees factices) ===\n'
printf '\n' | select_from_menu "Choisir un rôle :" "${OPTS[@]}" >/dev/null
printf '\n\n'

printf '=== Fleches ===\n'
run_case "bas, bas, Entree"                 '\033[B\033[B\n'             2
run_case "haut (bouclage), Entree"          '\033[A\n'                   3
run_case "bas x3, haut, Entree"             '\033[B\033[B\033[B\033[A\n' 2
run_case "bas x4 (bouclage complet)"        '\033[B\033[B\033[B\033[B\n' 0
run_case "Entree directe (defaut)"          '\n'                         0

printf '\n=== Numero ===\n'
run_case "4 puis Entree"                    '4\n'                        3
run_case "2 puis Entree"                    '2\n'                        1
run_case "1 puis Entree"                    '1\n'                        0

printf '\n=== Annulation (sentinel %s) ===\n' "$MENU_CANCELLED"
run_case "q immediat"                       'q'                          "" "$MENU_CANCELLED"
run_case "Q majuscule"                      'Q'                          "" "$MENU_CANCELLED"
run_case "bas, bas puis q"                  '\033[B\033[B q'             "" "$MENU_CANCELLED"
run_case "EOF (Ctrl-D)"                     ''                           "" "$MENU_CANCELLED"

printf '\n=== Cas limites ===\n'
run_case "9 (hors borne) puis 3"            '9\n3\n'                     2
run_case "0 (hors borne) puis 2"            '0\n2\n'                     1
run_case "1 backspace 4 puis Entree"        '1\177 4\n'                  3
run_case "bas puis numero 4"                '\033[B4\n'                  3

printf '\n=== Contrat d appel ===\n'
# Le sentinel ne doit pas retomber dans la plage des signaux (128+N) : le trap
# Ctrl+C du goal 4 doit rester distinguable d une annulation de menu.
if (( MENU_CANCELLED >= 128 || MENU_CANCELLED == 126 || MENU_CANCELLED == 127 )); then
    printf 'FAIL  MENU_CANCELLED=%s empiete sur une plage reservee\n' "$MENU_CANCELLED"
    fails=$((fails + 1))
else
    printf 'PASS  MENU_CANCELLED=%s hors plages reservees (126,127,128+N)\n' "$MENU_CANCELLED"
fi

if idx="$(printf 'q' | select_from_menu "T" "${OPTS[@]}" 2>/dev/null)"; then
    printf 'FAIL  q devrait faire echouer la substitution (idx="%s")\n' "$idx"
    fails=$((fails + 1))
else
    rc=$?
    if (( rc == MENU_CANCELLED )); then
        printf 'PASS  q -> branche else, rc == $MENU_CANCELLED (%s)\n' "$rc"
    else
        printf 'FAIL  rc inattendu apres q : %s\n' "$rc"
        fails=$((fails + 1))
    fi
fi

if select_from_menu "Sans options" </dev/null >/dev/null 2>&1; then
    printf 'FAIL  menu sans option devrait echouer\n'
    fails=$((fails + 1))
else
    printf 'PASS  menu sans option -> rc=%s\n' "$?"
fi

# ---------------------------------------------------------------------------
# 2. Suite interactive (TTY requis)
# ---------------------------------------------------------------------------

confirm() {
    local question="$1" answer
    read -r -p "      $question [o/N] " answer
    [[ "$answer" =~ ^[oOyY]$ ]]
}

check_manual() {
    local label="$1"
    if confirm "$2"; then
        printf 'PASS  %s\n\n' "$label"
    else
        printf 'FAIL  %s\n\n' "$label"
        fails=$((fails + 1))
    fi
}

printf '\n'
if (( ONLY_AUTO )); then
    printf '=== Suite interactive : SKIP (--auto) ===\n'
elif [[ ! -t 0 || ! -t 2 ]]; then
    printf '=== Suite interactive : SKIP (pas de terminal) ===\n'
    printf '    Le redessin ANSI in-place reste NON VALIDE.\n'
    printf '    Relancer depuis un vrai terminal : bash tests/test_menu.sh\n'
else
    printf '=== Suite interactive (rendu ANSI reel) ===\n\n'

    printf -- '--- 1/3 : navigation aux fleches ---\n'
    printf '      Descends puis remonte plusieurs fois, choisis "Global Reader" (3e), Entree.\n\n'
    idx="$(select_from_menu "Choisir un rôle :" "${OPTS[@]}")"
    rc=$?
    printf '\n      Retour : rc=%s idx=%s\n' "$rc" "${idx:-<vide>}"
    if [[ "$idx" == "2" && $rc -eq 0 ]]; then
        printf 'PASS  selection fleches -> index 2 (%s)\n' "${OPTS[2]}"
    else
        printf 'FAIL  attendu idx=2 rc=0, obtenu idx="%s" rc=%s\n' "$idx" "$rc"
        fails=$((fails + 1))
    fi
    check_manual "redessin ANSI in-place" \
        "Le menu s est redessine SUR PLACE (pas d empilement de copies) ?"
    check_manual "surlignage video inverse" \
        "La ligne courante etait surlignee et le surlignage suivait les fleches ?"

    printf -- '--- 2/3 : saisie numerique + backspace ---\n'
    printf '      Tape 1, efface au backspace, tape 4, Entree.\n\n'
    idx="$(select_from_menu "Choisir un rôle :" "${OPTS[@]}")"
    rc=$?
    printf '\n      Retour : rc=%s idx=%s\n' "$rc" "${idx:-<vide>}"
    if [[ "$idx" == "3" && $rc -eq 0 ]]; then
        printf 'PASS  selection numerique -> index 3 (%s)\n' "${OPTS[3]}"
    else
        printf 'FAIL  attendu idx=3 rc=0, obtenu idx="%s" rc=%s\n' "$idx" "$rc"
        fails=$((fails + 1))
    fi
    check_manual "echo de la saisie" \
        "Les chiffres tapes s affichaient apres l invite, et le backspace les effacait ?"

    printf -- '--- 3/3 : annulation ---\n'
    printf '      Appuie sur q.\n\n'
    idx="$(select_from_menu "Choisir un rôle :" "${OPTS[@]}")"
    rc=$?
    printf '\n      Retour : rc=%s idx=%s\n' "$rc" "${idx:-<vide>}"
    if [[ -z "$idx" && $rc -eq $MENU_CANCELLED ]]; then
        printf 'PASS  annulation -> rc=%s, aucune selection\n\n' "$rc"
    else
        printf 'FAIL  attendu idx vide rc=%s, obtenu idx="%s" rc=%s\n\n' "$MENU_CANCELLED" "$idx" "$rc"
        fails=$((fails + 1))
    fi
fi

printf '\n'
if (( fails == 0 )); then
    printf 'RESULTAT: tous les cas OK\n'
else
    printf 'RESULTAT: %s echec(s)\n' "$fails"
fi
exit $fails
