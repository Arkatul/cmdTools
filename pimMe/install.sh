#!/usr/bin/env bash
#
# install.sh — Rend pim-activate.sh appelable par son nom depuis n'importe où.
#
# Pose un lien symbolique « pim-activate » dans un répertoire bin utilisateur
# déjà présent dans $PATH. Un lien, pas une copie : le script installé suit les
# mises à jour du dépôt sans réinstallation.
#
# Usage :
#   ./install.sh [--bin-dir RÉPERTOIRE] [--uninstall] [-h|--help]
#
# Fonctionnement :
#   1. détection des répertoires bin utilisateur présents dans $PATH
#      (~/.local/bin et ~/bin au minimum) ;
#   2. si plusieurs conviennent, choix au clavier via le menu de
#      pim-activate.sh ; si un seul, il est retenu sans question ;
#   3. si aucun n'est dans $PATH, proposition de créer ~/.local/bin, puis
#      affichage de la ligne d'export à ajouter au shell rc ;
#   4. création du lien, refus d'écraser un fichier qui n'est pas déjà notre
#      lien ;
#   5. vérification finale par `command -v` dans un shell neuf.
#
# Ce que l'installeur n'écrit jamais :
#   - aucun fichier hors du répertoire bin retenu ;
#   - ni ~/.bashrc, ni ~/.profile, ni ~/.zshrc — la ligne d'export est
#     affichée, à vous de l'ajouter ;
#   - aucun sudo, aucune installation système.
#
# Codes de sortie :
#   0   succès (installation, réinstallation sans changement, désinstallation)
#   1   échec (script cible absent, conflit de nom, aucun répertoire choisi)
#   2   erreur d'usage (argument inconnu ou valeur manquante)
#
set -euo pipefail

INSTALLER_NAME="$(basename "${BASH_SOURCE[0]}")"
INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TARGET_SCRIPT="$INSTALLER_DIR/pim-activate.sh"
LINK_NAME="pim-activate"

# Nom des répertoires bin utilisateur testés en priorité, dans cet ordre.
PREFERRED_BIN_DIRS=("$HOME/.local/bin" "$HOME/bin")

# Répertoire par défaut créé quand aucun candidat n'est dans $PATH.
FALLBACK_BIN_DIR="$HOME/.local/bin"

# Entrées de $PATH sous $HOME ignorées comme candidats : ce sont des dépôts
# gérés par un outil (nvm, uv, dotnet…), pas des bin personnels.
EXCLUDED_PATH_PATTERNS=(
    "*/.nvm/*" "*/.cache/*" "*/.local/share/*" "*/.dotnet/*"
    "*/node_modules/*" "*/.venv/*" "*/.rustup/*" "*/.cargo/*"
)

# Réutilise le menu clavier, err() et info() de pim-activate.sh plutôt que d'en
# réécrire une variante. Le script cible est protégé par une garde de sourçage
# ([[ ${BASH_SOURCE[0]} == $0 ]]) : le charger ne déclenche pas son main.
if [[ ! -f "$TARGET_SCRIPT" ]]; then
    printf "Erreur : script introuvable : %s\n" "$TARGET_SCRIPT" >&2
    printf "Lancez %s depuis le dépôt, à côté de pim-activate.sh.\n" "$INSTALLER_NAME" >&2
    exit 1
fi
# shellcheck source=pim-activate.sh
source "$TARGET_SCRIPT"

# Le sourçage a écrasé SCRIPT_NAME et usage() : on rétablit les nôtres.
SCRIPT_NAME="$INSTALLER_NAME"

usage() {
    cat <<EOF
Usage: $INSTALLER_NAME [--bin-dir RÉPERTOIRE] [--uninstall] [-h|--help]

Installe « $LINK_NAME » dans un répertoire bin utilisateur de votre \$PATH, sous
forme de lien symbolique vers :
    $TARGET_SCRIPT

Options :
      --bin-dir DIR   Force le répertoire d'installation (aucun menu). Le
                      répertoire est créé s'il manque ; s'il n'est pas dans
                      \$PATH, la ligne d'export à ajouter est affichée.
      --uninstall     Retire le lien « $LINK_NAME » posé par cet installeur.
                      Un fichier qui n'est pas notre lien n'est jamais touché.
  -h, --help          Affiche cette aide et quitte.

Choix du répertoire :
  Les candidats sont les répertoires bin utilisateur présents dans \$PATH
  (~/.local/bin et ~/bin au minimum). Un seul candidat : il est retenu sans
  question. Plusieurs : le menu clavier de pim-activate.sh vous fait choisir
  (flèches ou numéro + Entrée, q pour annuler). Aucun : l'installeur propose de
  créer $FALLBACK_BIN_DIR et affiche la ligne d'export à ajouter.

Ce qui n'est jamais modifié :
  Rien n'est écrit hors du répertoire bin retenu. Ni ~/.bashrc, ni ~/.profile,
  ni ~/.zshrc ne sont touchés : la ligne d'export est seulement affichée. Aucun
  sudo, aucune installation système.

Idempotence :
  Relancer l'installeur sur une installation déjà en place ne change rien et
  sort en 0. Un fichier existant portant le nom « $LINK_NAME » et qui n'est pas
  un lien vers ce script fait échouer l'installation, sans écrasement.

Exemples :
  ./$INSTALLER_NAME                       # détection puis installation
  ./$INSTALLER_NAME --bin-dir ~/bin       # cible imposée, sans menu
  ./$INSTALLER_NAME --uninstall           # retire le lien
EOF
}

# ---------------------------------------------------------------------------
# Répertoires : $PATH et candidats
# ---------------------------------------------------------------------------

# Découpe $PATH en tableau. `read -ra` plutôt qu'un `for` sur $PATH non quoté :
# pas de glob involontaire sur une entrée contenant * ou ?.
path_entries() {
    local -a entries=()
    IFS=: read -r -a entries <<<"$PATH"
    printf '%s\n' "${entries[@]}"
}

# Vrai si $1 est une entrée de $PATH. Comparaison sur le chemin sans / final :
# « ~/bin » et « ~/bin/ » désignent le même répertoire.
path_contains() {
    local wanted="${1%/}" entry
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        [[ "${entry%/}" == "$wanted" ]] && return 0
    done < <(path_entries)
    return 1
}

is_excluded_path() {
    local dir="$1" pattern
    for pattern in "${EXCLUDED_PATH_PATTERNS[@]}"; do
        # shellcheck disable=SC2053  # glob volontaire à droite
        [[ "$dir/" == $pattern ]] && return 0
    done
    return 1
}

# Répertoires bin utilisateur présents dans $PATH, dans l'ordre de préférence :
# d'abord ~/.local/bin et ~/bin, puis les autres entrées de $PATH sous $HOME
# qui ressemblent à un bin personnel. Un candidat peut ne pas exister encore
# (déclaré dans le rc mais jamais créé) : il sera créé s'il est retenu.
collect_candidate_dirs() {
    local -a found=()
    local dir entry seen

    for dir in "${PREFERRED_BIN_DIRS[@]}"; do
        path_contains "$dir" && found+=("${dir%/}")
    done

    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        entry="${entry%/}"
        [[ "$entry" == "$HOME/"* ]] || continue
        [[ "$entry" == */bin ]] || continue
        is_excluded_path "$entry" && continue
        for seen in "${found[@]}"; do
            [[ "$seen" == "$entry" ]] && continue 2
        done
        found+=("$entry")
    done < <(path_entries)

    (( ${#found[@]} > 0 )) && printf '%s\n' "${found[@]}"
    return 0
}

# Libellé de menu : le répertoire, plus son état (existant, à créer, déjà
# occupé par un autre fichier).
dir_label() {
    local dir="$1" link="$1/$LINK_NAME"
    if [[ ! -d "$dir" ]]; then
        printf '%s  (à créer)' "$dir"
    elif [[ -e "$link" || -L "$link" ]]; then
        printf '%s  (contient déjà un fichier %s)' "$dir" "$LINK_NAME"
    elif [[ ! -w "$dir" ]]; then
        printf '%s  (non inscriptible)' "$dir"
    else
        printf '%s' "$dir"
    fi
}

# ---------------------------------------------------------------------------
# Liens : reconnaissance de ce que l'installeur a posé
# ---------------------------------------------------------------------------

target_real_path() {
    readlink -f "$TARGET_SCRIPT" 2>/dev/null || printf '%s' "$TARGET_SCRIPT"
}

# Vrai si $1 est un lien symbolique qui aboutit à pim-activate.sh — c'est-à-dire
# un lien que cet installeur a posé (ou l'équivalent exact).
is_our_link() {
    local candidate="$1" resolved
    [[ -L "$candidate" ]] || return 1
    resolved="$(readlink -f "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" && "$resolved" == "$(target_real_path)" ]]
}

# Répertoires de $PATH (plus les candidats, même hors $PATH) contenant déjà un
# fichier nommé $LINK_NAME. Sortie : « mine|dir » ou « foreign|dir ».
scan_installed_links() {
    local -a dirs=()
    local dir seen link

    while IFS= read -r dir; do
        [[ -n "$dir" ]] && dirs+=("${dir%/}")
    done < <(path_entries; collect_candidate_dirs)

    for dir in "${dirs[@]}"; do
        link="$dir/$LINK_NAME"
        [[ -e "$link" || -L "$link" ]] || continue
        for seen in "${_scan_seen[@]-}"; do
            [[ "$seen" == "$dir" ]] && continue 2
        done
        _scan_seen+=("$dir")
        if is_our_link "$link"; then
            printf 'mine|%s\n' "$dir"
        else
            printf 'foreign|%s\n' "$dir"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Choix du répertoire
# ---------------------------------------------------------------------------

# Menu oui/non bâti sur select_from_menu : même composant que le reste, pas de
# prompt ad hoc. Retour 0 = oui.
confirm_menu() {
    local prompt="$1" yes_label="$2" no_label="$3" choice rc=0
    choice="$(select_from_menu "$prompt" "$yes_label" "$no_label")" || rc=$?
    (( rc == 0 )) || return 1
    (( choice == 0 ))
}

# Écrit le répertoire retenu sur stdout. Retour 1 si l'utilisateur renonce.
choose_bin_dir() {
    local -a candidates=() labels=()
    local dir choice rc=0

    while IFS= read -r dir; do
        [[ -n "$dir" ]] && candidates+=("$dir")
    done < <(collect_candidate_dirs)

    case ${#candidates[@]} in
        0)
            info "Aucun répertoire bin utilisateur n'est présent dans votre \$PATH."
            if ! confirm_menu "Créer $FALLBACK_BIN_DIR et y installer $LINK_NAME ?" \
                "Créer $FALLBACK_BIN_DIR" "Annuler l'installation"; then
                return 1
            fi
            printf '%s\n' "$FALLBACK_BIN_DIR"
            ;;
        1)
            info "Répertoire retenu (seul candidat dans \$PATH) : ${candidates[0]}"
            printf '%s\n' "${candidates[0]}"
            ;;
        *)
            for dir in "${candidates[@]}"; do
                labels+=("$(dir_label "$dir")")
            done
            choice="$(select_from_menu \
                "Plusieurs répertoires bin sont dans votre \$PATH — où installer $LINK_NAME ?" \
                "${labels[@]}")" || rc=$?
            if (( rc != 0 )); then
                return 1
            fi
            printf '%s\n' "${candidates[$choice]}"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Vérification finale
# ---------------------------------------------------------------------------

# `command -v` dans un shell neuf : le shell courant a pu mettre en cache
# l'absence de la commande, un sous-shell bash refait la recherche dans $PATH.
resolved_command_path() {
    bash -c "command -v $LINK_NAME" 2>/dev/null || true
}

report_resolution() {
    local expected="$1" resolved
    resolved="$(resolved_command_path)"
    if [[ -z "$resolved" ]]; then
        info "Attention : « $LINK_NAME » n'est pas résolu par \$PATH pour l'instant."
        info "Ouvrez un nouveau shell (ou ajoutez la ligne d'export ci-dessus) puis réessayez."
        return 0
    fi
    if [[ -n "$expected" && "$resolved" != "$expected" ]]; then
        info "Attention : \$PATH résout d'abord $resolved, pas $expected."
    fi
    info "command -v $LINK_NAME → $resolved"
    return 0
}

print_export_hint() {
    local dir="$1"
    info ""
    info "$dir n'est pas dans votre \$PATH. Ajoutez cette ligne à votre shell rc"
    info "(~/.bashrc, ~/.profile ou ~/.zshrc) — l'installeur n'y touche pas :"
    info ""
    printf '    export PATH="%s:$PATH"\n' "$dir" >&2
    info ""
    info "Puis rechargez le shell : source ~/.bashrc"
    return 0
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

do_install() {
    local requested_dir="$1"
    local dir link entry state existing=""

    if [[ ! -x "$TARGET_SCRIPT" ]]; then
        info "Attention : $TARGET_SCRIPT n'est pas exécutable."
        info "Corrigez-le avec : chmod +x $TARGET_SCRIPT"
    fi

    # Déjà installé ? On ne repose rien et on ne pose surtout pas de question :
    # c'est ce qui rend une relance idempotente.
    while IFS='|' read -r state entry; do
        [[ "$state" == "mine" ]] || continue
        if [[ -z "$requested_dir" || "${requested_dir%/}" == "$entry" ]]; then
            existing="$entry"
            break
        fi
    done < <(scan_installed_links)

    if [[ -n "$existing" ]]; then
        info "Déjà installé : $existing/$LINK_NAME → $(target_real_path)"
        info "Rien à faire."
        path_contains "$existing" || print_export_hint "$existing"
        report_resolution "$existing/$LINK_NAME"
        return 0
    fi

    if [[ -n "$requested_dir" ]]; then
        dir="${requested_dir%/}"
        [[ "$dir" == /* ]] || dir="$(cd -- "$(dirname -- "$dir")" 2>/dev/null && pwd -P)/$(basename -- "$dir")" || dir="$requested_dir"
    else
        dir="$(choose_bin_dir)" || {
            err "Aucun répertoire choisi — rien n'a été installé."
            return 1
        }
    fi

    if [[ ! -d "$dir" ]]; then
        info "Création de $dir"
        mkdir -p -- "$dir"
    fi
    if [[ ! -w "$dir" ]]; then
        err "Répertoire non inscriptible : $dir"
        return 1
    fi

    link="$dir/$LINK_NAME"
    if [[ -e "$link" || -L "$link" ]]; then
        # Un lien à nous a déjà été traité plus haut : ici, c'est forcément un
        # autre fichier. On refuse plutôt que d'écraser le travail d'autrui.
        if [[ -L "$link" ]]; then
            err "$link est déjà un lien vers $(readlink -f "$link" 2>/dev/null || readlink "$link"), pas vers $TARGET_SCRIPT."
        else
            err "$link existe déjà et n'est pas un lien symbolique."
        fi
        err "Rien n'a été écrasé. Retirez ce fichier vous-même, ou choisissez un autre répertoire (--bin-dir)."
        return 1
    fi

    ln -s -- "$TARGET_SCRIPT" "$link"
    info "Lien posé : $link → $TARGET_SCRIPT"

    path_contains "$dir" || print_export_hint "$dir"
    report_resolution "$link"
    return 0
}

do_uninstall() {
    local requested_dir="$1"
    local state entry link removed=0 foreign=0

    while IFS='|' read -r state entry; do
        link="$entry/$LINK_NAME"
        if [[ -n "$requested_dir" && "${requested_dir%/}" != "$entry" ]]; then
            continue
        fi
        case "$state" in
            mine)
                rm -- "$link"
                info "Lien retiré : $link"
                removed=$(( removed + 1 ))
                ;;
            foreign)
                info "Ignoré (pas un lien posé par cet installeur) : $link"
                foreign=$(( foreign + 1 ))
                ;;
        esac
    done < <(scan_installed_links)

    if (( removed == 0 )); then
        if (( foreign > 0 )); then
            info "Aucun lien de cet installeur n'a été trouvé — rien n'a été retiré."
        else
            info "Rien à retirer : $LINK_NAME n'est pas installé."
        fi
        return 0
    fi

    # Contrôle du résultat : après retrait, plus rien ne doit répondre au nom.
    local resolved
    resolved="$(resolved_command_path)"
    if [[ -n "$resolved" ]]; then
        info "Attention : \$PATH résout encore $LINK_NAME → $resolved (autre installation)."
    else
        info "command -v $LINK_NAME → (rien)"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Entrée
# ---------------------------------------------------------------------------

main() {
    local action="install" bin_dir=""

    while (( $# > 0 )); do
        case "$1" in
            -h|--help) usage; return 0 ;;
            --uninstall) action="uninstall" ;;
            --bin-dir)
                if (( $# < 2 )); then
                    err "--bin-dir attend un répertoire."
                    return 2
                fi
                bin_dir="$2"
                shift
                ;;
            --bin-dir=*) bin_dir="${1#*=}" ;;
            --) shift; break ;;
            *)
                err "Argument inconnu : $1"
                info "Lancez « $INSTALLER_NAME --help » pour l'aide."
                return 2
                ;;
        esac
        shift
    done

    # Le menu bascule le terminal en raw : on réutilise les traps du script
    # cible pour ne pas laisser un terminal muet derrière nous.
    install_signal_traps
    trap restore_terminal_state EXIT

    # Tableau consommé par scan_installed_links pour dédoublonner $PATH.
    _scan_seen=()

    case "$action" in
        install) do_install "$bin_dir" ;;
        uninstall) do_uninstall "$bin_dir" ;;
    esac
}

main "$@"
