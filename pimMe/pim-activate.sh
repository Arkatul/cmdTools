#!/usr/bin/env bash
#
# pim-activate.sh — Activation interactive de rôles PIM Azure / Entra ID.
#
# Alternative rapide au portail pour activer un rôle éligible : liste les rôles
# activables de l'utilisateur connecté, en sélectionne un au clavier, demande
# une justification, soumet la demande d'activation et suit son statut jusqu'au
# provisionnement.
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
#   - jq   : parsing des réponses JSON et construction des corps de requête
#   - uuidgen (facultatif) : identifiant de la demande d'activation ARM ;
#            repli automatique sur /proc/sys/kernel/random/uuid
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

# Durée d'activation demandée (heures). L'API d'éligibilité n'expose pas le
# maximum autorisé par la politique PIM : la valeur est envoyée telle quelle et
# un refus de la politique est diagnostiqué par explain_az_error.
# Voir plan.md — hypothèse à ajuster selon le tenant.
DEFAULT_DURATION_HOURS=8

# Périmètre courant : azure | entra. Bascule à chaud par les touches a/e.
SCOPE="azure"

MENU_HINT="Flèches haut/bas + Entrée, numéro + Entrée, q pour annuler : "

# Code de retour de select_from_menu quand l'utilisateur annule (q ou EOF).
# Volontairement hors de la plage réservée par le shell : 126/127 (commande
# non exécutable/introuvable) et surtout 128+N pour les signaux — 130 = SIGINT.
# Le trap Ctrl+C du goal 4 doit rester distinguable d'une annulation de menu.
MENU_CANCELLED=64

# Touches d'action passées au menu par l'appelant (goal 2 : a/e pour basculer
# de scope). Vide par défaut : le contrat du goal 1 est inchangé.
MENU_HOTKEYS=()
# Retour de select_from_menu quand une hotkey est pressée : la touche est
# écrite sur stdout. Passer par stdout et non par une variable globale est
# imposé par l'appel en substitution de commande, qui isole le sous-shell.
MENU_HOTKEY_PRESSED=65

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

_menu_is_hotkey() {
    local candidate="$1" hotkey
    (( ${#MENU_HOTKEYS[@]} > 0 )) || return 1
    for hotkey in "${MENU_HOTKEYS[@]}"; do
        [[ "$candidate" == "$hotkey" ]] && return 0
    done
    return 1
}

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
        line="$(printf '%*d) %s' "${#count}" "$((i + 1))" "${_menu_options[$i]}")"
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
    printf '%s' "$MENU_HINT" >&2
    if (( ${#MENU_HOTKEYS[@]} > 0 )); then
        printf '(%s) ' "$(IFS='/'; printf '%s' "${MENU_HOTKEYS[*]}")" >&2
    fi
    printf '%s' "$_menu_typed" >&2
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
            *)
                if _menu_is_hotkey "$key"; then
                    printf '\n' >&2
                    printf '%s\n' "$key"
                    return "$MENU_HOTKEY_PRESSED"
                fi
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
    # </dev/null : az est ici le binaire Windows sous WSL et draine stdin, ce
    # qui volerait les frappes destinées au menu quand l'entrée est un pipe.
    if ! AZ_ACCOUNT_JSON="$(az account show -o json 2>"$az_err" </dev/null)"; then
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
# Récupération des rôles eligible
#
# Chemin de listing Azure retenu : scope racine "/" + $filter=asTarget().
#
# Le filtre `principalId eq '{objectId}'` prévu dans plan.md a été testé et
# renvoie systématiquement une liste vide sur ce tenant : les éligibilités y
# sont portées par des GROUPES (memberType=Inherited, principalType=Group), pas
# par des affectations directes à l'utilisateur. Un filtre sur l'objectId de
# l'utilisateur ne peut donc rien matcher. `asTarget()` résout au contraire
# l'appartenance transitive et retourne bien « ce à quoi j'ai droit ».
#
# Le fallback « boucle sur az account list » n'est pas nécessaire : appelé sur
# le scope racine, asTarget() cascade sur toute la hiérarchie (management
# groups + souscriptions) en UN appel. Vérifié en test réel : l'union des
# résultats par souscription est un sous-ensemble strict du résultat racine
# (les éligibilités portées au niveau management group n'apparaissent pas dans
# la boucle par souscription).
#
# Les parenthèses de asTarget() DOIVENT être encodées en %28%29 : ARM répond
# 400 "Bad Request - Invalid URL" sur les parenthèses brutes. Graph, lui, les
# accepte telles quelles.
# ---------------------------------------------------------------------------

ARM_API_VERSION="2020-10-01"
ARM_ELIGIBLE_URL="https://management.azure.com/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=${ARM_API_VERSION}&\$filter=asTarget%28%29"
GRAPH_ELIGIBLE_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances/filterByCurrentUser(on='principal')?%24expand=roleDefinition"

# Dernière erreur brute renvoyée par az rest, pour un diagnostic exploitable.
# Stockée dans un FICHIER et non dans une variable : les appelants invoquent
# az_rest_get en substitution de commande, dont le sous-shell ne peut pas
# propager une affectation de variable au processus parent.
AZ_REST_ERROR_FILE=""

init_az_rest_error_file() {
    AZ_REST_ERROR_FILE="$(mktemp)"
    trap 'rm -f "$AZ_REST_ERROR_FILE"' EXIT
}

az_rest_last_error() {
    [[ -n "$AZ_REST_ERROR_FILE" && -s "$AZ_REST_ERROR_FILE" ]] || return 0
    cat "$AZ_REST_ERROR_FILE"
}

# Appel GET commun aux deux API. stdin fermé : az est ici le binaire Windows
# sous WSL et draine stdin, ce qui volerait les frappes destinées au menu.
az_rest_get() {
    local url="$1" body rc=0

    : > "$AZ_REST_ERROR_FILE"
    # `|| rc=$?` et non `if ...; fi` puis `rc=$?` : après un `fi` dont aucune
    # branche n'a été prise, $? vaut 0 et masque l'échec de la commande.
    body="$(az rest --method get --url "$url" -o json 2>"$AZ_REST_ERROR_FILE" </dev/null)" || rc=$?

    (( rc == 0 )) || return "$rc"
    printf '%s' "$body"
}

# Tableaux parallèles décrivant les rôles du scope courant. Chaque entrée porte
# tout ce dont goal 3 a besoin pour construire la requête d'activation sans
# re-quêter l'API (cf. contrainte du goal 2).
ROLE_LABELS=()
ROLE_DEFINITION_IDS=()
ROLE_SCOPES=()
ROLE_SCHEDULE_IDS=()

reset_roles() {
    ROLE_LABELS=()
    ROLE_DEFINITION_IDS=()
    ROLE_SCOPES=()
    ROLE_SCHEDULE_IDS=()
}

# Alimente les tableaux depuis un flux TSV « label \t defId \t scope \t schedId ».
# Le TSV vient exclusivement de `jq -r ... | @tsv` : aucune regex sur du JSON.
ingest_roles_tsv() {
    local label def_id scope sched_id
    while IFS=$'\t' read -r label def_id scope sched_id; do
        [[ -n "$label" ]] || continue
        ROLE_LABELS+=("$label")
        ROLE_DEFINITION_IDS+=("$def_id")
        ROLE_SCOPES+=("$scope")
        ROLE_SCHEDULE_IDS+=("$sched_id")
    done
}

list_azure_roles() {
    local body

    if ! body="$(az_rest_get "$ARM_ELIGIBLE_URL")"; then
        err "Échec de la récupération des rôles Azure eligible."
        explain_az_error
        return 1
    fi

    # scope.displayName est plus lisible que l'ID ; on retombe sur l'ID brut
    # si l'API ne renvoie pas expandedProperties.
    ingest_roles_tsv < <(jq -r '
        .value[]
        | . as $i
        | [
            ( ($i.properties.expandedProperties.roleDefinition.displayName // $i.properties.roleDefinitionId)
              + "  —  "
              + ($i.properties.expandedProperties.scope.type // "scope")
              + " "
              + ($i.properties.expandedProperties.scope.displayName // $i.properties.scope) ),
            $i.properties.roleDefinitionId,
            $i.properties.scope,
            $i.properties.roleEligibilityScheduleId
          ]
        | @tsv
    ' <<<"$body" | sort)
}

list_entra_roles() {
    local body

    if ! body="$(az_rest_get "$GRAPH_ELIGIBLE_URL")"; then
        err "Échec de la récupération des rôles Entra eligible."
        explain_az_error
        return 1
    fi

    # Pour Entra, directoryScopeId tient le rôle du scope ARM ; "/" = tenant.
    ingest_roles_tsv < <(jq -r '
        .value[]
        | . as $i
        | [
            ( ($i.roleDefinition.displayName // $i.roleDefinitionId)
              + "  —  annuaire "
              + (if ($i.directoryScopeId // "/") == "/" then "tenant" else $i.directoryScopeId end) ),
            $i.roleDefinitionId,
            ($i.directoryScopeId // "/"),
            $i.id
          ]
        | @tsv
    ' <<<"$body" | sort)
}

# Charge les rôles du scope demandé. Retour 0 = chargé (éventuellement vide),
# 1 = échec d'appel.
load_roles() {
    local scope="$1"

    reset_roles
    case "$scope" in
        azure) list_azure_roles ;;
        entra) list_entra_roles ;;
        *) err "Scope inconnu : $scope"; return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Navigation
#
# Choix d'implémentation pour la bascule de scope : plutôt que de dupliquer une
# boucle de lecture clavier au-dessus du menu, select_from_menu accepte des
# touches d'action ($MENU_HOTKEYS) et rend la main avec $MENU_HOTKEY_PRESSED en
# écrivant la touche sur stdout. Une seule boucle de lecture, un seul rendu, et
# le contrat du goal 1 reste intact quand MENU_HOTKEYS est vide.
# ---------------------------------------------------------------------------

other_scope() {
    [[ "$1" == "azure" ]] && printf 'entra' || printf 'azure'
}

# Récapitulatif du rôle choisi, affiché juste avant le prompt de justification.
show_selection() {
    local index="$1"

    printf '\nRôle sélectionné :\n' >&2
    printf '  libellé              : %s\n' "${ROLE_LABELS[$index]}" >&2
    printf '  roleDefinitionId     : %s\n' "${ROLE_DEFINITION_IDS[$index]}" >&2
    printf '  scope                : %s\n' "${ROLE_SCOPES[$index]}" >&2
    printf '  schedule eligible    : %s\n' "${ROLE_SCHEDULE_IDS[$index]}" >&2
}

# Boucle de listing : affiche le scope courant, bascule sur a/e, sort sur q ou
# sélection. La boucle complète post-activation appartient au goal 4.
browse_roles() {
    local selection rc target

    while true; do
        info "Chargement des rôles eligible (scope ${SCOPE})…"
        if ! load_roles "$SCOPE"; then
            target="$(other_scope "$SCOPE")"
            info ""
            info "Impossible de lister le scope ${SCOPE}."
            if ! prompt_scope_switch "$target"; then
                return 1
            fi
            SCOPE="$target"
            continue
        fi

        if (( ${#ROLE_LABELS[@]} == 0 )); then
            target="$(other_scope "$SCOPE")"
            info ""
            info "Aucun rôle eligible sur ce scope (${SCOPE})."
            if ! prompt_scope_switch "$target"; then
                return 0
            fi
            SCOPE="$target"
            continue
        fi

        MENU_HOTKEYS=("a" "e")
        # `x="$(cmd)"` qui échoue sort du script sous set -e avant tout rc=$? :
        # on capture le code dans la même commande composée.
        rc=0
        selection="$(select_from_menu \
            "Rôles ${SCOPE} eligible (${#ROLE_LABELS[@]}) — a=azure e=entra q=quitter :" \
            "${ROLE_LABELS[@]}")" || rc=$?
        MENU_HOTKEYS=()

        case $rc in
            0)
                # `cmd; return $?` ne suffit pas sous set -e : un échec de
                # activate_role sortirait du script avant le return.
                rc=0
                activate_role "$selection" || rc=$?
                return "$rc"
                ;;
            "$MENU_HOTKEY_PRESSED")
                case "$selection" in
                    a) SCOPE="azure" ;;
                    e) SCOPE="entra" ;;
                esac
                ;;
            "$MENU_CANCELLED")
                info "Annulé."
                return 0
                ;;
            *)
                err "Retour inattendu du menu : $rc"
                return 1
                ;;
        esac
    done
}

# Propose de basculer vers l'autre scope quand le courant est vide ou en échec.
prompt_scope_switch() {
    local target="$1" answer

    read -r -p "Basculer vers le scope ${target} ? [o/N] " answer || return 1
    [[ "$answer" =~ ^[oOyY]$ ]]
}

# ---------------------------------------------------------------------------
# Flux d'activation
#
# principalId : sur ce tenant les éligibilités sont portées par des GROUPES
# (cf. section listing) — `properties.principalId` d'une instance vaut donc
# l'objectId du GROUPE, jamais celui de l'utilisateur, et ne peut pas servir de
# principalId à un SelfActivate. L'objectId de l'utilisateur est lu dans la
# claim `oid` du jeton ARM plutôt que via `az ad signed-in-user show` : cela
# n'ajoute aucune dépendance à Graph, dont ce tenant refuse déjà certaines
# permissions à l'app Azure CLI (cf. explain_az_error).
#
# Le corps JSON part en argument `--body` et non via `@fichier` : az est ici le
# binaire Windows sous WSL et ne saurait pas lire un chemin WSL. Vérifié :
# l'interop WSL préserve guillemets et accents dans argv.
# ---------------------------------------------------------------------------

# Placeholder « business » proposé à l'écran, éditable avant validation.
DEFAULT_JUSTIFICATION="Intervention support — troubleshooting"

# Polling du statut de la demande. Pas de workflow d'approbation en v1
# (cf. plan.md) : on affiche l'état et on sort au bout du timeout.
POLL_INTERVAL_SECONDS=4
POLL_TIMEOUT_SECONDS=60

GRAPH_REQUESTS_URL="https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests"

AZ_PRINCIPAL_ID=""
JUSTIFICATION=""
POLL_URL=""

# Traduit les erreurs az récurrentes en message actionnable, puis affiche le
# détail brut. Partagé par le listing et l'activation.
explain_az_error() {
    local raw
    raw="$(az_rest_last_error)"

    case "$raw" in
        *PermissionScopeNotGranted*)
            err "L'application Azure CLI n'a pas les permissions Graph requises sur ce tenant."
            err "Un administrateur doit consentir RoleManagement.Read.Directory (ou"
            err "RoleEligibilitySchedule.Read.Directory) pour l'app 04b07795-8ddb-461a-bbee-02f9e1bf7b46."
            ;;
        *AADSTS70043*|*token_expired*|*invalid_grant*)
            err "Session Azure CLI expirée (sign-in frequency de l'accès conditionnel)."
            err "Relancez 'az login --tenant ${AZ_TENANT_ID:-<tenant>}' puis réessayez."
            ;;
        *AADSTS50076*|*AADSTS50079*|*MFA*|*mfa*|*claims*)
            err "Ce rôle exige une authentification forte (MFA) récente."
            err "Relancez 'az login --scope https://graph.microsoft.com//.default' puis réessayez."
            ;;
        *RoleAssignmentRequestPolicyValidationFailed*|*MaximumDuration*|*maximum*duration*)
            err "Durée demandée refusée par la politique PIM du rôle."
            err "Baissez DEFAULT_DURATION_HOURS (actuellement ${DEFAULT_DURATION_HOURS}h) en tête de script."
            ;;
    esac

    if [[ -n "$raw" ]]; then
        printf '%s\n' "$raw" >&2
    fi
    return 0
}

# Extrait la claim `oid` du payload d'un JWT (base64url, padding tronqué).
_jwt_oid() {
    local payload="$1" pad

    payload="${payload//-/+}"
    payload="${payload//_//}"
    pad=$(( (4 - ${#payload} % 4) % 4 ))
    while (( pad-- > 0 )); do
        payload+="="
    done

    printf '%s' "$payload" | base64 -d 2>/dev/null | jq -r '.oid // empty' 2>/dev/null
}

# Résout (une seule fois) l'objectId de l'utilisateur connecté.
resolve_principal_id() {
    local token

    if [[ -n "$AZ_PRINCIPAL_ID" ]]; then
        return 0
    fi

    : > "$AZ_REST_ERROR_FILE"
    if token="$(az account get-access-token --resource https://management.azure.com/ \
                    --query accessToken -o tsv 2>"$AZ_REST_ERROR_FILE" </dev/null)"; then
        AZ_PRINCIPAL_ID="$(_jwt_oid "$(cut -d. -f2 <<<"$token")")"
    fi

    # Repli si la claim manque : format de jeton inattendu, identité applicative.
    if [[ -z "$AZ_PRINCIPAL_ID" ]]; then
        AZ_PRINCIPAL_ID="$(az ad signed-in-user show --query id -o tsv \
                               2>"$AZ_REST_ERROR_FILE" </dev/null || true)"
    fi

    if [[ -z "$AZ_PRINCIPAL_ID" ]]; then
        err "Impossible de déterminer l'objectId de l'utilisateur connecté."
        explain_az_error
        return 1
    fi
}

# Saisie pré-remplie et éditable en place (readline). Entrée valide le texte
# affiché à l'écran : le placeholder ne part jamais sans ce passage explicite.
# Ligne vidée + Entrée = annulation.
# Écrit dans $JUSTIFICATION plutôt que sur stdout : avec `read -e`, readline
# écrit l'écho de la ligne, qu'une substitution de commande capturerait.
prompt_justification() {
    local answer=""

    JUSTIFICATION=""
    printf '\n' >&2
    if ! IFS= read -r -e -i "$DEFAULT_JUSTIFICATION" \
            -p "Justification (Entrée valide, ligne vide annule) : " answer; then
        printf '\n' >&2
        return "$MENU_CANCELLED"
    fi

    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"
    if [[ -z "$answer" ]]; then
        return "$MENU_CANCELLED"
    fi

    JUSTIFICATION="$answer"
}

new_request_guid() {
    local guid
    if command -v uuidgen >/dev/null 2>&1; then
        guid="$(uuidgen)"
    else
        guid="$(< /proc/sys/kernel/random/uuid)"
    fi
    printf '%s' "${guid,,}"
}

iso_utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Appel avec corps JSON, même gestion d'erreur que az_rest_get.
az_rest_send() {
    local method="$1" url="$2" body="$3" out rc=0

    : > "$AZ_REST_ERROR_FILE"
    out="$(az rest --method "$method" --url "$url" \
              --headers "Content-Type=application/json" \
              --body "$body" -o json 2>"$AZ_REST_ERROR_FILE" </dev/null)" || rc=$?

    (( rc == 0 )) || return "$rc"
    printf '%s' "$out"
}

# $2 vide = corps sans linkedRoleEligibilityScheduleId.
_azure_activation_body() {
    local index="$1" linked="$2"

    jq -n \
        --arg principalId "$AZ_PRINCIPAL_ID" \
        --arg roleDefinitionId "${ROLE_DEFINITION_IDS[$index]}" \
        --arg justification "$JUSTIFICATION" \
        --arg start "$(iso_utc_now)" \
        --arg duration "PT${DEFAULT_DURATION_HOURS}H" \
        --arg linked "$linked" \
        '{properties: ({
            principalId: $principalId,
            roleDefinitionId: $roleDefinitionId,
            requestType: "SelfActivate",
            justification: $justification,
            scheduleInfo: {
                startDateTime: $start,
                expiration: { type: "AfterDuration", duration: $duration }
            }
          } + (if $linked == "" then {} else { linkedRoleEligibilityScheduleId: $linked } end))}'
}

# Soumission ARM. `linkedRoleEligibilityScheduleId` est optionnel côté API :
# on tente d'abord sans, et on ne rejoue avec que si l'API le réclame — la doc
# ne le rend obligatoire dans aucun cas, seul le test tranche (cf. goal 3).
submit_azure_activation() {
    local index="$1" guid url

    guid="$(new_request_guid)"
    url="https://management.azure.com${ROLE_SCOPES[$index]}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/${guid}?api-version=${ARM_API_VERSION}"

    if az_rest_send PUT "$url" "$(_azure_activation_body "$index" "")" >/dev/null; then
        POLL_URL="$url"
        return 0
    fi

    if az_rest_last_error | grep -qi 'linkedRoleEligibilityScheduleId'; then
        info "L'API réclame la schedule eligible liée — nouvelle tentative."
        if az_rest_send PUT "$url" \
               "$(_azure_activation_body "$index" "${ROLE_SCHEDULE_IDS[$index]}")" >/dev/null; then
            POLL_URL="$url"
            return 0
        fi
    fi

    err "Échec de la soumission de l'activation Azure."
    explain_az_error
    return 1
}

# Graph attend `afterDuration` en camelCase là où ARM attend `AfterDuration`.
_entra_activation_body() {
    local index="$1"

    jq -n \
        --arg principalId "$AZ_PRINCIPAL_ID" \
        --arg roleDefinitionId "${ROLE_DEFINITION_IDS[$index]}" \
        --arg directoryScopeId "${ROLE_SCOPES[$index]}" \
        --arg justification "$JUSTIFICATION" \
        --arg start "$(iso_utc_now)" \
        --arg duration "PT${DEFAULT_DURATION_HOURS}H" \
        '{
            action: "selfActivate",
            principalId: $principalId,
            roleDefinitionId: $roleDefinitionId,
            directoryScopeId: $directoryScopeId,
            justification: $justification,
            scheduleInfo: {
                startDateTime: $start,
                expiration: { type: "afterDuration", duration: $duration }
            }
        }'
}

submit_entra_activation() {
    local index="$1" response id

    if ! response="$(az_rest_send POST "$GRAPH_REQUESTS_URL" "$(_entra_activation_body "$index")")"; then
        err "Échec de la soumission de l'activation Entra."
        explain_az_error
        return 1
    fi

    id="$(jq -r '.id // empty' <<<"$response")"
    if [[ -z "$id" ]]; then
        err "Réponse Graph sans identifiant de demande — impossible de suivre le statut."
        return 1
    fi

    POLL_URL="${GRAPH_REQUESTS_URL}/${id}"
}

# Les deux API partagent le vocabulaire de statuts (Provisioned, Granted,
# PendingApproval, Failed…) ; seule l'orthographe de Cancelled/Canceled et
# l'emplacement du champ diffèrent.
_request_status() {
    if [[ "$SCOPE" == "azure" ]]; then
        jq -r '.properties.status // empty'
    else
        jq -r '.status // empty'
    fi
}

# 0 = provisionné, 1 = échec API, 2 = toujours en attente au timeout.
poll_activation() {
    local elapsed=0 body status last=""

    printf 'Attente du provisionnement ' >&2
    while (( elapsed < POLL_TIMEOUT_SECONDS )); do
        if body="$(az_rest_get "$POLL_URL")"; then
            status="$(_request_status <<<"$body")"
            if [[ -n "$status" ]]; then
                last="$status"
            fi
            case "$status" in
                Provisioned|Granted)
                    printf '\n' >&2
                    info "Rôle activé (${status}) pour ${DEFAULT_DURATION_HOURS}h."
                    return 0
                    ;;
                Failed|Denied|Revoked|Cancelled|Canceled)
                    printf '\n' >&2
                    err "Activation en échec (statut ${status})."
                    jq -c '.' <<<"$body" >&2
                    return 1
                    ;;
            esac
        fi
        printf '.' >&2
        sleep "$POLL_INTERVAL_SECONDS"
        elapsed=$(( elapsed + POLL_INTERVAL_SECONDS ))
    done

    printf '\n' >&2
    info "Toujours en attente après ${POLL_TIMEOUT_SECONDS}s (dernier statut : ${last:-inconnu})."
    info "Une demande soumise à approbation continue d'être traitée côté portail ;"
    info "le workflow d'approbation n'est pas géré par ce script (cf. plan.md)."
    return 2
}

# Enchaîne récapitulatif → justification → soumission → polling.
# Un timeout de polling n'est pas une erreur du script : il remonte 0.
activate_role() {
    local index="$1" rc=0

    show_selection "$index"

    if ! prompt_justification; then
        info "Activation annulée."
        return 0
    fi

    resolve_principal_id || return 1

    info ""
    info "Soumission de la demande (${DEFAULT_DURATION_HOURS}h)…"
    case "$SCOPE" in
        azure) submit_azure_activation "$index" || return 1 ;;
        entra) submit_entra_activation "$index" || return 1 ;;
        *) err "Scope inconnu : $SCOPE"; return 1 ;;
    esac

    poll_activation || rc=$?
    if (( rc == 2 )); then
        rc=0
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# Entrée
# ---------------------------------------------------------------------------

main() {
    # Ordre volontaire : la validation des arguments précède tout contact avec
    # az, pour que --help et une valeur invalide n'aient aucun coût réseau.
    parse_args "$@" || return $?

    require_dependencies || return 1
    init_az_rest_error_file
    check_azure_session || return 1

    info "Connecté en tant que ${AZ_USER_NAME} (tenant ${AZ_TENANT_ID})."

    browse_roles
}

# Garde de sourçage : permet de charger le script pour tester select_from_menu
# isolément sans exécuter main.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
