#!/usr/bin/env bash
#
# pim-activate.sh — Activation interactive de rôles PIM de ressources Azure.
#
# Alternative rapide au portail pour activer un rôle éligible : liste les rôles
# activables de l'utilisateur connecté, en sélectionne un au clavier, demande
# une justification, soumet la demande d'activation et suit son statut jusqu'au
# provisionnement — puis revient à la liste pour enchaîner une autre activation
# sans relancer le script. Seuls les rôles de ressources Azure sont gérés : les
# rôles d'annuaire Entra ID sont hors périmètre.
#
# Usage :
#   ./pim-activate.sh [-h|--help]
#
#   -h, --help    Affiche l'aide détaillée et quitte.
#
# Fonctionnement :
#   1. liste des rôles Azure éligibles (scope racine, filtre asTarget) ;
#   2. sélection au clavier (flèches ou numéro), r rafraîchit, q quitte ;
#   3. justification saisie à l'écran, obligatoire sur les rôles sensibles ;
#   4. lecture de la durée max dans la policy PIM du rôle, puis soumission
#      SelfActivate et polling du statut jusqu'au provisionnement ;
#   5. retour automatique à la liste rafraîchie, quel que soit le résultat.
#
# Prérequis :
#   - bash 4+ (tableaux, read -rsn1) — pas de compatibilité sh POSIX visée
#   - az   : Azure CLI, avec une session active (`az login` au préalable ;
#            le script ne déclenche jamais de login automatique)
#   - jq   : parsing des réponses JSON et construction des corps de requête
#   - uuidgen (facultatif) : identifiant de la demande d'activation ARM ;
#            repli automatique sur /proc/sys/kernel/random/uuid
#
# Limitations connues (cf. plan.md, section « hors scope ») :
#   - pas de désactivation d'un rôle actif — passer par le portail ;
#   - pas de gestion du workflow d'approbation : une demande en
#     PendingApproval est affichée puis abandonnée au bout de 60s, elle
#     continue d'être traitée côté portail ;
#   - mono-tenant : le tenant est celui de la session az courante ;
#   - rôles d'annuaire Entra ID non gérés (chemin Graph retiré).
#
# Codes de sortie :
#   0   succès (y compris sortie volontaire par q)
#   1   prérequis manquant ou session Azure absente/illisible
#   2   erreur d'usage (argument inconnu)
#
# Note : $MENU_CANCELLED (64) et $ACTIVATION_INTERRUPTED (65) sont des retours
# de fonction internes, pas des codes de sortie du script.
#
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# Durée de repli (heures), utilisée uniquement quand la policy PIM du rôle est
# illisible (appel en échec, réponse inattendue). Volontairement basse : mieux
# vaut une activation courte qu'un refus de la politique. La durée nominale est
# lue par activation dans la policy du rôle (cf. resolve_activation_duration).
FALLBACK_DURATION_HOURS=1

# Durée ISO 8601 retenue pour l'activation en cours (ex. PT8H, P1D). Renseignée
# par resolve_activation_duration juste avant la soumission, et consommée par le
# corps de requête puis par le message de succès.
ACTIVATION_DURATION=""


MENU_HINT="Flèches haut/bas + Entrée, numéro + Entrée, q pour annuler : "

# Code de retour de select_from_menu quand l'utilisateur annule (q ou EOF).
# Volontairement hors de la plage réservée par le shell : 126/127 (commande
# non exécutable/introuvable) et surtout 128+N pour les signaux — 130 = SIGINT.
# Le trap Ctrl+C du goal 4 doit rester distinguable d'une annulation de menu.
MENU_CANCELLED=64

# Retour de fonction quand l'utilisateur interrompt (Ctrl+C) une saisie ou une
# attente : l'appelant doit revenir à la liste, pas quitter. Comme
# $MENU_CANCELLED, la valeur reste hors de la plage 128+N des signaux pour
# rester distinguable d'une mort par signal.
ACTIVATION_INTERRUPTED=65

# Positionné par le trap SIGINT, consommé (et remis à 0) par les boucles qui
# peuvent être interrompues. Un trap bash ne peut pas « casser » la boucle en
# cours : il ne fait que lever ce drapeau, que les boucles testent.
INTERRUPTED=0

# Réglages tty d'origine, restaurés après une interruption : `read -rsn1` bascule
# le terminal en raw/-echo, et une saisie tuée en plein vol laisserait sinon un
# terminal muet ou sans curseur.
SAVED_STTY=""

# Touches d'action passées au menu par l'appelant (goal 4 : r pour recharger
# la liste). Vide par défaut : le contrat du goal 1 est inchangé.
MENU_HOTKEYS=()
# Retour de select_from_menu quand une hotkey est pressée : la touche est
# écrite sur stdout. Passer par stdout et non par une variable globale est
# imposé par l'appel en substitution de commande, qui isole le sous-shell.
MENU_HOTKEY_PRESSED=65

usage() {
    cat <<EOF
Usage: $SCRIPT_NAME [-h|--help]

Activation interactive de rôles PIM de ressources Azure, en alternative au
portail. Le script liste les rôles éligibles de l'utilisateur connecté, en
active un après saisie d'une justification, suit le provisionnement, puis
revient à la liste rafraîchie pour enchaîner sans redémarrer. Seuls les rôles
de ressources Azure sont gérés : les rôles d'annuaire Entra ID sont hors
périmètre.

Options:
  -h, --help          Affiche cette aide et quitte.

Navigation dans la liste:
  Flèches haut/bas    Déplace la sélection
  1..N puis Entrée    Sélectionne directement par numéro
  Entrée              Active le rôle surligné
  r                   Recharge la liste depuis l'API
  q                   Quitte le script (code 0)
  Ctrl+C              Annule la saisie ou l'attente en cours et revient
                      à la liste ; ne quitte jamais brutalement

Justification:
  Une justification est proposée pré-remplie et éditable en place. Sur les
  rôles sensibles (Owner, User Access Administrator) elle est obligatoire :
  aucun texte n'est pré-rempli et une saisie vide est refusée.

Prérequis:
  az connecté (az login) et jq disponibles dans le PATH.

Limitations connues:
  - pas de désactivation d'un rôle actif (portail) ;
  - workflow d'approbation non géré : une demande PendingApproval est
    affichée puis abandonnée après ${POLL_TIMEOUT_SECONDS}s de polling, sans être annulée ;
  - mono-tenant : le tenant est celui de la session az courante.

Exemples:
  # Lister les rôles Azure éligibles et en activer un
  $SCRIPT_NAME

  # Afficher cette aide
  $SCRIPT_NAME --help

Durée d'activation:
  La durée maximale autorisée est propre à chaque rôle et à chaque scope. Elle
  est lue dans la policy PIM du rôle sélectionné (règle
  Expiration_EndUser_Assignment) juste avant la soumission, et affichée. Si
  cette lecture échoue, le script se replie sur ${FALLBACK_DURATION_HOURS}h
  (constante FALLBACK_DURATION_HOURS) plutôt que d'abandonner l'activation.
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
# Interruptions et état du terminal
#
# Un trap bash ne peut pas « casser » la boucle en cours : il lève un drapeau
# ($INTERRUPTED) que les boucles interruptibles consomment via take_interrupt.
# Les substitutions de commande (`x="$(select_from_menu …)"`, `az rest`) sont
# des sous-shells, où bash réinitialise les traps aux valeurs par défaut : le
# sous-shell meurt du signal et c'est le shell parent, lui trappé, qui lève le
# drapeau. Chaque appelant en substitution constate donc l'interruption après
# coup, sur son propre retour.
# ---------------------------------------------------------------------------

save_terminal_state() {
    if [[ -t 0 ]]; then
        SAVED_STTY="$(stty -g 2>/dev/null || true)"
    fi
    return 0
}

# Rend le terminal utilisable après une saisie tuée en plein vol : `read -rsn1`
# l'a basculé en raw/-echo, et readline peut avoir masqué le curseur.
restore_terminal_state() {
    if [[ -n "$SAVED_STTY" && -t 0 ]]; then
        stty "$SAVED_STTY" 2>/dev/null || true
    fi
    if [[ -t 2 ]]; then
        printf '\033[?25h' >&2
    fi
    return 0
}

on_interrupt() {
    INTERRUPTED=1
    restore_terminal_state
    printf '\n' >&2
    info "Interruption (Ctrl+C) — retour à la liste."
    return 0
}

# Consomme le drapeau : 0 si une interruption était en attente (et elle est
# alors remise à zéro), 1 sinon. Un drapeau non consommé ferait traiter la même
# interruption deux fois.
take_interrupt() {
    (( INTERRUPTED )) || return 1
    INTERRUPTED=0
    return 0
}

install_signal_traps() {
    save_terminal_state
    trap on_interrupt INT
    # SIGTERM/SIGHUP ne sont pas rattrapables en « retour au menu » : on rend
    # simplement le terminal avant de partir.
    trap 'restore_terminal_state; exit 143' TERM
    trap 'restore_terminal_state; exit 129' HUP
    return 0
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

        # EOF (Ctrl-D) traité comme une annulation. Une interruption, elle,
        # ne fait que redemander une touche : le menu reste à l'écran.
        # (Chemin utile quand le menu tourne dans le shell trappé ; en
        # substitution de commande, c'est l'appelant qui constate le signal.)
        if ! IFS= read -rsn1 key; then
            if take_interrupt; then
                _menu_drawn=0
                continue
            fi
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

# Le script n'a qu'un seul mode d'appel : pas d'option de périmètre, le
# listing ARM est le seul chemin. Tout argument inconnu reste une erreur
# d'usage (code 2) accompagnée de l'aide, plutôt qu'un silence.
parse_args() {
    while (( $# > 0 )); do
        case "$1" in
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
# 400 "Bad Request - Invalid URL" sur les parenthèses brutes.
# ---------------------------------------------------------------------------

ARM_API_VERSION="2020-10-01"
ARM_ELIGIBLE_URL="https://management.azure.com/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=${ARM_API_VERSION}&\$filter=asTarget%28%29"

# Dernière erreur brute renvoyée par az rest, pour un diagnostic exploitable.
# Stockée dans un FICHIER et non dans une variable : les appelants invoquent
# az_rest_get en substitution de commande, dont le sous-shell ne peut pas
# propager une affectation de variable au processus parent.
AZ_REST_ERROR_FILE=""

init_az_rest_error_file() {
    AZ_REST_ERROR_FILE="$(mktemp)"
    trap 'rm -f "$AZ_REST_ERROR_FILE"; restore_terminal_state' EXIT
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

# Tableaux parallèles décrivant les rôles éligibles chargés. Chaque entrée porte
# tout ce dont goal 3 a besoin pour construire la requête d'activation sans
# re-quêter l'API (cf. contrainte du goal 2).
ROLE_LABELS=()
ROLE_DEFINITION_IDS=()
ROLE_SCOPES=()
ROLE_SCHEDULE_IDS=()
# Nom brut du rôle, séparé du libellé d'affichage (qui y colle le scope) :
# la règle de justification obligatoire s'y adosse sans découper une chaîne
# destinée à l'œil.
ROLE_NAMES=()

reset_roles() {
    ROLE_LABELS=()
    ROLE_DEFINITION_IDS=()
    ROLE_SCOPES=()
    ROLE_SCHEDULE_IDS=()
    ROLE_NAMES=()
}

# Alimente les tableaux depuis un flux TSV
# « label \t defId \t scope \t schedId \t nom ».
# Le TSV vient exclusivement de `jq -r ... | @tsv` : aucune regex sur du JSON.
ingest_roles_tsv() {
    local label def_id scope sched_id name
    while IFS=$'\t' read -r label def_id scope sched_id name; do
        [[ -n "$label" ]] || continue
        ROLE_LABELS+=("$label")
        ROLE_DEFINITION_IDS+=("$def_id")
        ROLE_SCOPES+=("$scope")
        ROLE_SCHEDULE_IDS+=("$sched_id")
        ROLE_NAMES+=("$name")
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
            $i.properties.roleEligibilityScheduleId,
            ($i.properties.expandedProperties.roleDefinition.displayName // "")
          ]
        | @tsv
    ' <<<"$body" | sort)
}

# Charge les rôles éligibles. Retour 0 = chargé (éventuellement vide),
# 1 = échec d'appel.
load_roles() {
    reset_roles
    list_azure_roles
}

# ---------------------------------------------------------------------------
# Navigation
#
# Choix d'implémentation pour les touches d'action (r) : plutôt que de dupliquer
# une boucle de lecture clavier au-dessus du menu, select_from_menu accepte des
# touches d'action ($MENU_HOTKEYS) et rend la main avec $MENU_HOTKEY_PRESSED en
# écrivant la touche sur stdout. Une seule boucle de lecture, un seul rendu, et
# le contrat du goal 1 reste intact quand MENU_HOTKEYS est vide.
# ---------------------------------------------------------------------------

# Récapitulatif du rôle choisi, affiché juste avant le prompt de justification.
show_selection() {
    local index="$1"

    printf '\nRôle sélectionné :\n' >&2
    printf '  libellé              : %s\n' "${ROLE_LABELS[$index]}" >&2
    printf '  roleDefinitionId     : %s\n' "${ROLE_DEFINITION_IDS[$index]}" >&2
    printf '  scope                : %s\n' "${ROLE_SCOPES[$index]}" >&2
    printf '  schedule eligible    : %s\n' "${ROLE_SCHEDULE_IDS[$index]}" >&2
}

# Après une liste vide ou un échec d'appel : recharger ou quitter. Sans ce
# point d'arrêt, « revenir à la liste » sur une erreur persistante (réseau
# coupé, droits manquants) boucle indéfiniment sans jamais rendre la main.
prompt_retry_or_quit() {
    local answer rc=0

    # Substitution de commande obligatoire ici aussi : cf. _read_line_edited.
    answer="$(_read_line_edited "" "Recharger la liste ? [O/n] ")" || rc=$?
    if (( rc != 0 )); then
        # Ctrl+C ou EOF sur cette question : on ne relance pas une liste qui
        # vient d'échouer, on rend la main.
        take_interrupt || printf '\n' >&2
        return 1
    fi
    [[ ! "$answer" =~ ^[[:space:]]*[nNqQ] ]]
}

# Boucle principale : liste → sélection → activation → retour à la liste
# rafraîchie, indéfiniment. Aucun retour d'activate_role ne quitte le script :
# succès, échec API et annulation ramènent tous à la liste. Seules sorties :
# `q` au menu (code 0), refus de recharger après un échec, ou une erreur fatale
# de session détectée par main.
browse_roles() {
    local selection rc

    while true; do
        info "Chargement des rôles eligible…"
        # `load_roles` échouant sous set -e sortirait du script avant tout
        # test : le code est capturé dans la même commande composée.
        rc=0
        load_roles || rc=$?

        # Une interruption pendant le chargement ne doit pas être lue comme un
        # échec d'API : on recharge simplement.
        if take_interrupt; then
            continue
        fi

        if (( rc != 0 )); then
            info ""
            info "Impossible de lister les rôles éligibles."
            prompt_retry_or_quit || return 0
            continue
        fi

        if (( ${#ROLE_LABELS[@]} == 0 )); then
            info ""
            info "Aucun rôle eligible sur ce périmètre."
            prompt_retry_or_quit || return 0
            continue
        fi

        MENU_HOTKEYS=("r")
        # `x="$(cmd)"` qui échoue sort du script sous set -e avant tout rc=$? :
        # on capture le code dans la même commande composée.
        rc=0
        selection="$(select_from_menu \
            "Rôles eligible (${#ROLE_LABELS[@]}) — Entrée active, r recharge, q quitte :" \
            "${ROLE_LABELS[@]}")" || rc=$?
        MENU_HOTKEYS=()

        # Ctrl+C au clavier : le menu tourne dans un sous-shell de
        # substitution, aux traps réinitialisés — il meurt du signal (rc 130)
        # et c'est ici, dans le shell parent trappé, qu'on le constate.
        if take_interrupt || (( rc > 128 )); then
            continue
        fi

        case $rc in
            0)
                # Tout retour ramène à la liste : un échec d'activation n'est
                # pas une raison de quitter (goal 4, gestion d'erreurs globale).
                activate_role "$selection" || true
                ;;
            "$MENU_HOTKEY_PRESSED")
                # Seule hotkey déclarée : r = recharger la liste.
                ;;
            "$MENU_CANCELLED")
                info "Sortie."
                return 0
                ;;
            *)
                err "Retour inattendu du menu : $rc"
                return 1
                ;;
        esac
    done
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

# Rôles sensibles : justification obligatoire, non vide, et surtout AUCUN texte
# pré-rempli — un placeholder validé d'un coup d'Entrée ne documente rien et
# c'est précisément sur ces deux rôles que la trace doit être réelle.
# Reconnaissance par GUID de rôle intégré (stable, indépendant de la langue du
# tenant) ET par nom, au cas où l'API ne renvoie pas le displayName attendu.
STRICT_JUSTIFICATION_ROLE_GUIDS=(
    "8e3af657-a8ff-443c-a75c-2fe8c4bcb635"  # Owner
    "18d7d88d-d35e-4fb5-a5c3-7773c20a72d9"  # User Access Administrator
)
STRICT_JUSTIFICATION_ROLE_NAMES=(
    "owner"
    "user access administrator"
)

# Polling du statut de la demande. Pas de workflow d'approbation en v1
# (cf. plan.md) : on affiche l'état et on sort au bout du timeout.
POLL_INTERVAL_SECONDS=4
POLL_TIMEOUT_SECONDS=60

AZ_PRINCIPAL_ID=""
JUSTIFICATION=""
POLL_URL=""

# 0 = le rôle d'indice $1 exige une justification saisie à la main.
justification_is_mandatory() {
    local index="$1" guid name candidate

    name="${ROLE_NAMES[$index]:-}"
    name="${name,,}"
    for candidate in "${STRICT_JUSTIFICATION_ROLE_NAMES[@]}"; do
        [[ "$name" == "$candidate" ]] && return 0
    done

    # roleDefinitionId ARM = .../roleDefinitions/{guid} : seul le GUID compte.
    guid="${ROLE_DEFINITION_IDS[$index]##*/}"
    guid="${guid,,}"
    for candidate in "${STRICT_JUSTIFICATION_ROLE_GUIDS[@]}"; do
        [[ "$guid" == "$candidate" ]] && return 0
    done

    return 1
}

# Traduit les erreurs az récurrentes en message actionnable, puis affiche le
# détail brut. Partagé par le listing et l'activation.
explain_az_error() {
    local raw
    raw="$(az_rest_last_error)"

    case "$raw" in
        *PermissionScopeNotGranted*)
            err "L'application Azure CLI n'a pas les permissions Graph requises sur ce tenant."
            err "Seul le repli de résolution de l'objectId (az ad signed-in-user show) en"
            err "dépend : le listing et l'activation n'appellent que l'API ARM."
            ;;
        *AADSTS70043*|*token_expired*|*invalid_grant*)
            err "Session Azure CLI expirée (sign-in frequency de l'accès conditionnel)."
            err "Relancez 'az login --tenant ${AZ_TENANT_ID:-<tenant>}' puis réessayez."
            ;;
        *AADSTS50076*|*AADSTS50079*|*MFA*|*mfa*|*claims*)
            err "Ce rôle exige une authentification forte (MFA) récente."
            err "Relancez 'az login --tenant ${AZ_TENANT_ID:-<tenant>}' en validant le"
            err "second facteur, puis réessayez."
            ;;
        *RoleAssignmentExists*|*RoleAssignmentRequestExists*)
            err "Ce rôle est déjà actif (ou une demande est déjà en cours) sur ce scope."
            err "Attendez son expiration ou désactivez-le dans le portail PIM."
            ;;
        *RoleAssignmentRequestPolicyValidationFailed*|*MaximumDuration*|*maximum*duration*|*ExpirationRule*)
            err "Durée refusée par la politique PIM du rôle (${ACTIVATION_DURATION:-inconnue} demandée)."
            err "La durée a pourtant été lue dans la policy du rôle : la règle a pu"
            err "changer entre-temps, ou l'activation exige une date de fin explicite."
            err "Vérifiez la règle Expiration_EndUser_Assignment du rôle dans le portail."
            ;;
        *"Connection aborted"*|*"Max retries exceeded"*|*"Failed to establish a new connection"*|\
        *"Name or service not known"*|*"Temporary failure in name resolution"*|\
        *"Read timed out"*|*"ConnectionError"*|*"SSLError"*|*"Network is unreachable"*)
            err "Appel Azure impossible : le réseau ou le service ne répond pas."
            err "Vérifiez la connectivité (proxy, VPN, DNS) puis rechargez la liste."
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

# Lit une ligne éditable en place (readline) et l'écrit sur stdout.
#
# À appeler EN SUBSTITUTION DE COMMANDE, et pas autrement : bash quitte le
# script lorsqu'un signal frappe le builtin `read` du shell principal, même
# trappé — le trap s'exécute puis le shell part. Dans un sous-shell de
# substitution, les traps sont réinitialisés : c'est le sous-shell qui meurt
# (retour 130) et le shell parent, lui, poursuit et voit l'interruption.
#
# readline écrit invite et écho sur stdout, que la substitution capturerait
# avec la réponse : ils sont renvoyés vers le terminal. Hors terminal, readline
# est de toute façon inactif et il n'y a rien à afficher.
_read_line_edited() {
    local prefill="$1" prompt="$2" answer="" echo_to=/dev/null

    if [[ -t 2 && -w /dev/tty ]]; then
        echo_to=/dev/tty
    fi

    IFS= read -r -e -i "$prefill" -p "$prompt" answer >"$echo_to" || return $?
    printf '%s' "$answer"
}

# Saisie éditée en place (readline). Entrée valide le texte affiché à l'écran :
# le placeholder ne part jamais sans ce passage explicite.
#
# Deux régimes, selon le rôle passé en argument (indice dans les tableaux de
# rôles ; sans argument, régime standard) :
#   - standard : placeholder pré-rempli et modifiable, ligne vide = annulation ;
#   - obligatoire (Owner, User Access Administrator) : rien de pré-rempli, une
#     ligne vide est refusée et la question est reposée. Ctrl+C annule.
#
# Écrit dans $JUSTIFICATION plutôt que sur stdout : avec `read -e`, readline
# écrit l'écho de la ligne, qu'une substitution de commande capturerait.
prompt_justification() {
    local index="${1-}" answer="" prefill="$DEFAULT_JUSTIFICATION" prompt mandatory=0 rc=0

    JUSTIFICATION=""

    if [[ -n "$index" ]] && justification_is_mandatory "$index"; then
        mandatory=1
        prefill=""
    fi

    printf '\n' >&2
    if (( mandatory )); then
        info "Rôle sensible (${ROLE_NAMES[$index]:-${ROLE_LABELS[$index]}}) :"
        info "justification obligatoire, aucun texte n'est pré-rempli."
        prompt="Justification obligatoire (Ctrl+C annule) : "
    else
        prompt="Justification (Entrée valide, ligne vide annule) : "
    fi

    while true; do
        answer=""
        rc=0
        answer="$(_read_line_edited "$prefill" "$prompt")" || rc=$?
        if (( rc != 0 )); then
            # Ctrl+C : le trap a rendu la main au terminal, on remonte un code
            # distinct pour que l'appelant reparte sur la liste. Sinon (EOF),
            # c'est une annulation ordinaire.
            if take_interrupt || (( rc > 128 )); then
                return "$ACTIVATION_INTERRUPTED"
            fi
            printf '\n' >&2
            return "$MENU_CANCELLED"
        fi

        answer="${answer#"${answer%%[![:space:]]*}"}"
        answer="${answer%"${answer##*[![:space:]]}"}"

        if [[ -n "$answer" ]]; then
            JUSTIFICATION="$answer"
            return 0
        fi

        if (( mandatory == 0 )); then
            return "$MENU_CANCELLED"
        fi

        err "Justification obligatoire pour ce rôle : saisissez un motif (Ctrl+C pour annuler)."
    done
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

# ---------------------------------------------------------------------------
# Durée d'activation : lecture de la policy PIM du rôle
#
# La durée maximale n'est pas portée par l'éligibilité mais par la policy du
# rôle, qui dépend du couple (scope, roleDefinitionId) : une constante globale
# se fait refuser dès qu'un rôle est plus restrictif que les autres
# (RoleAssignmentRequestPolicyValidationFailed sur l'ExpirationRule).
#
# La règle qui gouverne une auto-activation est Expiration_EndUser_Assignment ;
# les règles Expiration_Admin_* concernent l'attribution par un administrateur
# et ne s'appliquent pas ici.
# ---------------------------------------------------------------------------

# Rend une durée ISO 8601 lisible (PT8H -> « 8 h », P1D -> « 1 j »). Une forme
# inattendue est rendue telle quelle : mieux vaut afficher PT45S que mentir.
humanize_duration() {
    local iso="$1" out="" days hours minutes

    [[ "$iso" =~ ^P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?)?$ ]] || { printf '%s' "$iso"; return 0; }
    days="${BASH_REMATCH[1]%D}"
    hours="${BASH_REMATCH[3]%H}"
    minutes="${BASH_REMATCH[4]%M}"
    [[ -n "$days" ]] && out+="${days} j "
    [[ -n "$hours" ]] && out+="${hours} h "
    [[ -n "$minutes" ]] && out+="${minutes} min "
    out="${out% }"
    printf '%s' "${out:-$iso}"
}

# Extrait la durée max d'auto-activation d'une réponse roleManagementPolicy-
# Assignments. Vide si la règle est absente ou la réponse inattendue.
_max_duration_from_policy() {
    jq -r '
        [ .value[]?.properties.effectiveRules[]?
          | select(.id == "Expiration_EndUser_Assignment")
          | .maximumDuration // empty ]
        | first // empty
    ' 2>/dev/null
}

# Renseigne $ACTIVATION_DURATION pour le rôle $1 et affiche la durée retenue.
# Un seul appel de policy par activation. Ne rend jamais la main en échec : une
# policy illisible se replie sur FALLBACK_DURATION_HOURS, l'activation courte
# valant mieux qu'un abandon.
resolve_activation_duration() {
    local index="$1" url body duration=""

    # $filter encodé (%24, %20, %27) : l'URL part telle quelle dans az rest, où
    # un $ nu serait mangé par le shell et une apostrophe nue par l'API.
    url="https://management.azure.com${ROLE_SCOPES[$index]}/providers/Microsoft.Authorization/roleManagementPolicyAssignments?api-version=${ARM_API_VERSION}&%24filter=roleDefinitionId%20eq%20%27${ROLE_DEFINITION_IDS[$index]}%27"

    if body="$(az_rest_get "$url")"; then
        duration="$(_max_duration_from_policy <<<"$body")"
    fi

    if [[ "$duration" =~ ^P([0-9]+D)?(T([0-9]+H)?([0-9]+M)?)?$ && "$duration" != "P" ]]; then
        ACTIVATION_DURATION="$duration"
        info "Durée retenue : $(humanize_duration "$duration") (policy du rôle, maximumDuration ${duration})."
        return 0
    fi

    ACTIVATION_DURATION="PT${FALLBACK_DURATION_HOURS}H"
    if [[ -n "$duration" ]]; then
        info "Durée de policy inexploitable ('${duration}')."
    else
        info "Policy PIM du rôle illisible : $(az_rest_last_error | head -1)"
    fi
    info "Durée retenue : $(humanize_duration "$ACTIVATION_DURATION") (repli FALLBACK_DURATION_HOURS)."
    return 0
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
        --arg duration "$ACTIVATION_DURATION" \
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


# Statut de la demande ARM. Le vocabulaire est celui de PIM (Provisioned,
# Granted, PendingApproval, Failed…), l'orthographe de Cancelled/Canceled
# variant selon les endpoints — les deux sont traitées à l'appel.
_request_status() {
    jq -r '.properties.status // empty'
}

# 0 = provisionné, 1 = échec API, 2 = toujours en attente au timeout,
# $ACTIVATION_INTERRUPTED = Ctrl+C pendant l'attente.
#
# Ni l'appel az (sous-shell de substitution) ni `sleep` ne rendent la main
# d'eux-mêmes sur signal : le trap lève le drapeau, la boucle le consomme au
# tour suivant et sort — la demande, elle, reste soumise côté Azure.
poll_activation() {
    local elapsed=0 body status last=""

    printf 'Attente du provisionnement ' >&2
    while (( elapsed < POLL_TIMEOUT_SECONDS )); do
        if take_interrupt; then
            info "Attente interrompue — la demande reste soumise côté Azure."
            info "Son état est consultable dans le portail PIM."
            return "$ACTIVATION_INTERRUPTED"
        fi

        if body="$(az_rest_get "$POLL_URL")"; then
            status="$(_request_status <<<"$body")"
            if [[ -n "$status" ]]; then
                last="$status"
            fi
            case "$status" in
                Provisioned|Granted)
                    printf '\n' >&2
                    info "Rôle activé (${status}) pour $(humanize_duration "$ACTIVATION_DURATION")."
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
        # Échec d'appel isolé (réseau qui tombe en cours de polling) : on ne
        # sort pas, la demande peut encore aboutir — le prochain tour réessaie.
        printf '.' >&2
        sleep "$POLL_INTERVAL_SECONDS" || true
        elapsed=$(( elapsed + POLL_INTERVAL_SECONDS ))
    done

    printf '\n' >&2
    info "Toujours en attente après ${POLL_TIMEOUT_SECONDS}s (dernier statut : ${last:-inconnu})."
    info "Une demande soumise à approbation continue d'être traitée côté portail ;"
    info "le workflow d'approbation n'est pas géré par ce script (cf. plan.md)."
    return 2
}

# Enchaîne récapitulatif → justification → soumission → polling.
# Ne remonte JAMAIS de code destiné à faire quitter le script : la boucle
# principale reprend la main dans tous les cas. Un timeout de polling et une
# interruption ne sont pas des erreurs (retour 0) ; un échec d'API remonte 1
# pour la trace, mais ramène lui aussi à la liste.
activate_role() {
    local index="$1" rc=0

    show_selection "$index"

    prompt_justification "$index" || rc=$?
    case $rc in
        0) ;;
        "$ACTIVATION_INTERRUPTED")
            info "Activation abandonnée avant soumission."
            return 0
            ;;
        *)
            info "Activation annulée."
            return 0
            ;;
    esac

    rc=0
    resolve_principal_id || rc=$?
    if (( rc != 0 )); then
        take_interrupt || true
        return 1
    fi

    info ""
    resolve_activation_duration "$index"

    # Un Ctrl+C pendant l'appel de policy ne doit pas se solder par une
    # soumission surprise : on s'arrête avant, comme pour la justification.
    if take_interrupt; then
        info "Activation abandonnée avant soumission."
        return 0
    fi

    info "Soumission de la demande ($(humanize_duration "$ACTIVATION_DURATION"))…"
    rc=0
    submit_azure_activation "$index" || rc=$?
    if (( rc != 0 )); then
        # Une soumission interrompue au clavier a pu laisser le drapeau levé :
        # on le consomme ici pour que la liste ne reparte pas sur un faux signal.
        take_interrupt || true
        return 1
    fi

    rc=0
    poll_activation || rc=$?
    case $rc in
        2|"$ACTIVATION_INTERRUPTED") rc=0 ;;
    esac
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
    install_signal_traps
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
