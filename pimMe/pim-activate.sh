#!/usr/bin/env bash
#
# pim-activate.sh — Activation interactive de rôles PIM Azure / Entra ID.
#
# Alternative rapide au portail pour activer un rôle éligible : liste les rôles
# activables de l'utilisateur connecté, en sélectionne un au clavier, et soumet
# la demande d'activation.
#
# Usage :
#   ./pim-activate.sh [-s|--scope azure|entra] [-h|--help]
#
#   -s, --scope   Périmètre des rôles à lister : azure (rôles de ressources
#                 Azure) ou entra (rôles d'annuaire Entra ID). Défaut : azure.
#   -h, --help    Affiche l'aide et quitte.
#
# Prérequis :
#   - bash 4+ (tableaux, read -rsn1) — pas de compatibilité sh POSIX visée
#   - az   : Azure CLI, avec une session active (`az login` au préalable ;
#            le script ne déclenche jamais de login automatique)
#   - jq   : parsing des réponses JSON
#
# Codes de sortie :
#   0   succès
#   1   prérequis manquant ou session Azure absente/illisible
#   2   erreur d'usage (argument inconnu ou valeur invalide)
#
# Note : $MENU_CANCELLED (64) est un retour de fonction interne, pas un code de
# sortie du script — voir select_from_menu.
#

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# Durée d'activation par défaut (heures), utilisée par le flux d'activation
# (goal 3) lorsque la politique PIM n'expose pas de maximum exploitable.
# Voir plan.md — hypothèse à ajuster selon le tenant.
DEFAULT_DURATION_HOURS=8

# Périmètre courant : azure | entra. Bascule à chaud prévue au goal 2.
SCOPE="azure"

MENU_HINT="Flèches haut/bas + Entrée, numéro + Entrée, q pour annuler : "

# Code de retour de select_from_menu quand l'utilisateur annule (q ou EOF).
# Volontairement hors de la plage réservée par le shell : 126/127 (commande
# non exécutable/introuvable) et surtout 128+N pour les signaux — 130 = SIGINT.
# Le trap Ctrl+C du goal 4 doit rester distinguable d'une annulation de menu.
MENU_CANCELLED=64

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [-s|--scope azure|entra] [-h|--help]

Activation interactive de rôles PIM (rôles de ressources Azure et rôles
d'annuaire Entra ID), en alternative au portail.

Options:
  -s, --scope SCOPE   Périmètre des rôles : azure ou entra (défaut: ${SCOPE})
  -h, --help          Affiche cette aide et quitte

Prérequis:
  az connecté (az login) et jq disponibles dans le PATH.

Exemples:
  $SCRIPT_NAME
  $SCRIPT_NAME --scope entra
EOF
}

err() {
    printf "Erreur : %s\n" "$*" >&2
}

info() {
    printf "%s\n" "$*" >&2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        err "Commande requise introuvable : $1. Installez-la puis réessayez."
        return 1
    }
}

require_dependencies() {
    local cmd
    for cmd in az jq; do
        require_command "$cmd" || return 1
    done
}

# ---------------------------------------------------------------------------
# Menu interactif réutilisable
#
#   if index="$(select_from_menu "Titre" "opt 1" "opt 2" ...)"; then
#       printf 'choisi : %s\n' "$index"
#   else
#       (( $? == MENU_CANCELLED )) && printf 'annulé\n'
#   fi
#
# Rend le menu sur stderr, écrit l'index sélectionné (0-based) sur stdout.
# Navigation : flèches haut/bas (avec bouclage) + Entrée, ou saisie directe
# d'un numéro 1-based + Entrée. Backspace corrige la saisie.
# 'q' ou EOF annule sans sélection : rien sur stdout, retour $MENU_CANCELLED.
# Ce sentinel évite la plage 128+N des signaux, pour qu'un Ctrl+C intercepté
# par un trap (goal 4) reste distinguable d'une annulation volontaire.
# Bash pur — aucune dépendance externe (pas de fzf).
# ---------------------------------------------------------------------------

_menu_render() {
    local count=${#_menu_options[@]}
    local i line

    if (( _menu_drawn )); then
        # Hors terminal (pipe, test) le curseur n'est pas adressable :
        # on rend une seule fois plutôt que d'empiler des redraws.
        [[ -t 2 ]] || return 0
        printf '\033[%dA\r\033[J' "$((count + 1))" >&2
    fi

    printf '%s\n' "$_menu_prompt" >&2
    for i in "${!_menu_options[@]}"; do
        line="$(printf '%d) %s' "$((i + 1))" "${_menu_options[$i]}")"
        if (( i == _menu_selected )); then
            if [[ -t 2 ]]; then
                printf '\033[7m> %s\033[0m\n' "$line" >&2
            else
                printf '> %s\n' "$line" >&2
            fi
        else
            printf '  %s\n' "$line" >&2
        fi
    done
    printf '%s%s' "$MENU_HINT" "$_menu_typed" >&2
    _menu_drawn=1
}

select_from_menu() {
    local _menu_prompt="$1"
    shift
    local _menu_options=("$@")
    local _menu_selected=0
    local _menu_typed=""
    local _menu_drawn=0
    local count=${#_menu_options[@]}
    local key rest

    if (( count == 0 )); then
        err "select_from_menu : aucune option fournie"
        return 1
    fi

    while true; do
        _menu_render

        # EOF (Ctrl-D) traité comme une annulation.
        if ! IFS= read -rsn1 key; then
            printf '\n' >&2
            return "$MENU_CANCELLED"
        fi

        case "$key" in
            $'\e')
                # Séquence ANSI : ESC [ A (haut) / ESC [ B (bas).
                rest=""
                read -rsn2 -t 0.2 rest || rest=""
                case "$rest" in
                    '[A') _menu_selected=$(( (_menu_selected - 1 + count) % count )); _menu_typed="" ;;
                    '[B') _menu_selected=$(( (_menu_selected + 1) % count )); _menu_typed="" ;;
                esac
                ;;
            '')
                # Entrée : valide la saisie numérique si présente, sinon le surlignage.
                if [[ -n "$_menu_typed" ]]; then
                    if [[ "$_menu_typed" =~ ^[0-9]+$ ]] \
                        && (( 10#$_menu_typed >= 1 && 10#$_menu_typed <= count )); then
                        _menu_selected=$(( 10#$_menu_typed - 1 ))
                    else
                        # Hors borne : on efface la saisie et on redemande.
                        _menu_typed=""
                        continue
                    fi
                fi
                break
                ;;
            [0-9])
                _menu_typed+="$key"
                ;;
            $'\177'|$'\b')
                _menu_typed="${_menu_typed%?}"
                ;;
            q|Q)
                printf '\n' >&2
                return "$MENU_CANCELLED"
                ;;
        esac
    done

    printf '\n' >&2
    printf '%d\n' "$_menu_selected"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

validate_scope() {
    case "$1" in
        azure|entra) return 0 ;;
        *)
            err "Périmètre invalide : '$1' (valeurs attendues : azure, entra)"
            return 1
            ;;
    esac
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -s|--scope)
                [[ $# -ge 2 ]] || { err "Option $1 : valeur manquante"; return 2; }
                SCOPE="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                err "Option inconnue : $1"
                usage >&2
                return 2
                ;;
            *)
                err "Argument inattendu : $1"
                usage >&2
                return 2
                ;;
        esac
    done

    validate_scope "$SCOPE" || return 2
}

# ---------------------------------------------------------------------------
# Session Azure
# ---------------------------------------------------------------------------

AZ_ACCOUNT_JSON=""
AZ_USER_NAME=""
AZ_TENANT_ID=""

# Vérifie qu'une session az est active. Ne déclenche jamais `az login` :
# on informe et on sort, la décision de se connecter revient à l'utilisateur.
check_azure_session() {
    local az_err

    az_err="$(mktemp)"
    if ! AZ_ACCOUNT_JSON="$(az account show -o json 2>"$az_err")"; then
        err "Aucune session Azure CLI active. Lancez 'az login' puis réessayez."
        if [[ -s "$az_err" ]]; then
            printf "Détail az : %s\n" "$(head -n 1 "$az_err")" >&2
        fi
        rm -f "$az_err"
        return 1
    fi
    rm -f "$az_err"

    if ! AZ_USER_NAME="$(jq -re '.user.name // empty' <<<"$AZ_ACCOUNT_JSON")"; then
        err "Session Azure illisible : impossible de déterminer l'utilisateur connecté."
        return 1
    fi

    if ! AZ_TENANT_ID="$(jq -re '.tenantId // empty' <<<"$AZ_ACCOUNT_JSON")"; then
        err "Session Azure illisible : impossible de déterminer le tenant."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Entrée
# ---------------------------------------------------------------------------

main() {
    # Ordre volontaire : la validation des arguments précède tout contact avec
    # az, pour que --help et une valeur invalide n'aient aucun coût réseau.
    parse_args "$@" || return $?

    require_dependencies || return 1
    check_azure_session || return 1

    info "Connecté en tant que ${AZ_USER_NAME} (tenant ${AZ_TENANT_ID})."
    info "Périmètre courant : ${SCOPE}."
    info "Socle prêt — le listing des rôles éligibles arrive au goal 2."
}

# Garde de sourçage : permet de charger le script pour tester select_from_menu
# isolément sans exécuter main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
