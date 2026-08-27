#!/usr/bin/env bash
#
# tests/test_interrupt.sh — Ctrl+C et état du terminal (pim-activate.sh, goal 4).
#
# Le signal est envoyé au GROUPE de processus, exactement comme le fait un
# terminal sur Ctrl+C : la cible est lancée via `setsid` pour disposer de son
# propre groupe, et `kill -INT -$pgid` frappe le script ET l'`az` qu'il attend.
#
# Situations couvertes :
#   A. interruption pendant le polling (poll_activation, appels az réels) ;
#   B. interruption pendant l'attente clavier du menu ;
#   C. interruption pendant la saisie de la justification ;
#   D. réglages tty et curseur après interruption (terminal non cassé).
#
# Usage :
#   bash tests/test_interrupt.sh
#
set -uo pipefail

# Job control obligatoire : sans lui, bash lance les tâches d'arrière-plan avec
# SIGINT *ignoré*, et un signal ignoré à l'entrée d'un shell ne peut plus y être
# trappé — le script testé ne verrait jamais le Ctrl+C simulé. En usage réel il
# tourne au premier plan d'un terminal, où le signal arrive normalement.
set -m

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TEST_DIR}/../pim-activate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fails=0
check() {
    local label="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then
        printf 'PASS  %-50s -> %s\n' "$label" "$got"
    else
        printf 'FAIL  %-50s -> attendu "%s", obtenu "%s"\n' "$label" "$expected" "$got"
        fails=$((fails + 1))
    fi
}

CHILD_PGID=""
CHILD_JOB=""

# Lance une commande dans sa propre session (donc son propre groupe), stdin
# branché sur $1 (fifo ou /dev/null), sortie fusionnée dans $2.
spawn_child() {
    local stdin_path="$1" log="$2"; shift 2
    local pidfile="${WORK}/pgid"

    : > "$log"
    rm -f "$pidfile"
    setsid bash -c 'echo $$ > "$0"; exec "${@:3}" < "$1" > "$2" 2>&1' \
        "$pidfile" "$stdin_path" "$log" "$@" &
    CHILD_JOB=$!

    local waited=0
    while [[ ! -s "$pidfile" ]] && (( waited < 100 )); do
        sleep 0.1; waited=$((waited + 1))
    done
    CHILD_PGID="$(cat "$pidfile" 2>/dev/null)"
    [[ -n "$CHILD_PGID" ]]
}

# Attend l'apparition d'un motif dans le log (timeout en secondes).
wait_for() {
    local log="$1" pattern="$2" limit="${3:-60}" waited=0
    while (( waited < limit * 2 )); do
        grep -q "$pattern" "$log" 2>/dev/null && return 0
        sleep 0.5; waited=$((waited + 1))
    done
    return 1
}

interrupt_child() {
    kill -INT -"$CHILD_PGID" 2>/dev/null \
        || printf 'ATTENTION : signal non délivré au groupe %s\n' "$CHILD_PGID" >&2
}

printf '=== A. Ctrl+C pendant le polling (appels az réels) ===\n'

# Runner : le vrai poll_activation, sur une demande d'activation inexistante.
# Chaque GET échoue sans statut terminal : la boucle tourne jusqu'au timeout de
# 60s — fenêtre large et déterministe pour recevoir le signal.
cat > "${WORK}/poll_runner.sh" <<RUNNER
#!/usr/bin/env bash
source "${TARGET}"
install_signal_traps
init_az_rest_error_file
POLL_URL="https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/11111111-1111-1111-1111-111111111111?api-version=2020-10-01"
rc=0
poll_activation || rc=\$?
printf 'RC=%s\n' "\$rc"
RUNNER

log="${WORK}/poll.log"
spawn_child /dev/null "$log" bash "${WORK}/poll_runner.sh"
wait_for "$log" 'Attente du provisionnement' 30
sleep 2
start=$SECONDS
interrupt_child
wait "$CHILD_JOB"
elapsed=$(( SECONDS - start ))

check "message d'interruption affiché" "1" "$(grep -c 'Attente interrompue' "$log")"
check "demande signalée comme soumise"  "1" "$(grep -c 'reste soumise côté Azure' "$log")"
check "code ACTIVATION_INTERRUPTED"     "RC=65" "$(grep -m1 '^RC=' "$log")"
check "sortie immédiate, pas au timeout" "ok" "$( (( elapsed < 20 )) && echo ok || echo ko)"
check "pas de trace set -e brute"       "0" "$(grep -c ': line [0-9]*:' "$log")"

printf '\n=== B. Ctrl+C pendant l attente clavier du menu ===\n'

fifo="${WORK}/in.b"; mkfifo "$fifo"
log="${WORK}/menu.log"
# Ouverture en lecture-écriture : `exec 9>fifo` seul bloquerait jusqu'à ce
# qu'un lecteur se présente.
exec 9<>"$fifo"
spawn_child "$fifo" "$log" "$TARGET"
wait_for "$log" 'q pour annuler' 90
interrupt_child
wait_for "$log" 'Interruption (Ctrl+C)' 30
# Le menu est réaffiché après rechargement : q quitte alors.
wait_for "$log" 'Chargement des rôles eligible.*\n.*' 5
printf 'q' >&9
wait "$CHILD_JOB"; rc_b=$?
exec 9>&-

check "interruption signalée"           "1" "$(grep -c 'Interruption (Ctrl+C) — retour à la liste' "$log")"
check "liste rechargée après le signal"  "ok" \
    "$( (( $(grep -c 'Chargement des rôles eligible' "$log") >= 2 )) && echo ok || echo ko)"
check "q quitte ensuite proprement"      "1" "$(grep -c '^Sortie\.' "$log")"
check "code de sortie 0"                 "0" "$rc_b"

printf '\n=== C. Ctrl+C pendant la saisie de la justification ===\n'

fifo="${WORK}/in.c"; mkfifo "$fifo"
log="${WORK}/just.log"
exec 9<>"$fifo"
spawn_child "$fifo" "$log" "$TARGET"
wait_for "$log" 'q pour annuler' 90
printf '1\n' >&9
wait_for "$log" 'Justification' 30
interrupt_child
wait_for "$log" 'Activation abandonnée avant soumission' 30
printf 'q' >&9
wait "$CHILD_JOB"; rc_c=$?
exec 9>&-

check "saisie interrompue signalée"      "1" "$(grep -c 'Interruption (Ctrl+C)' "$log")"
check "abandon avant soumission"         "1" "$(grep -c 'Activation abandonnée avant soumission' "$log")"
check "aucune demande soumise"           "0" "$(grep -c 'Soumission de la demande' "$log")"
check "retour à la liste"                "ok" \
    "$( (( $(grep -c 'Chargement des rôles eligible' "$log") >= 2 )) && echo ok || echo ko)"
check "code de sortie 0"                 "0" "$rc_c"

printf '\n=== D. État du terminal après interruption ===\n'

# Le seul test qui exige un VRAI terminal : `read -rsn1` bascule le tty en
# raw/-echo, et c'est cet état-là qu'une interruption pourrait laisser derrière
# elle. Un pty est fourni par python3 (script(1) ferait aussi l'affaire mais
# n'est pas installé partout) ; à défaut, le cas est sauté, pas silencieusement
# déclaré vert.
if command -v python3 >/dev/null 2>&1; then
    cat > "${WORK}/pty_driver.py" <<'PYDRV'
"""Lance une commande dans un pty, envoie SIGINT quand un motif apparaît, puis
tape 'q'. Sortie du pty recopiée sur stdout. argv: <log> <cmd...>"""
import os, pty, re, signal, sys, time

log_path, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)

buf, sent_int, sent_q, deadline = b"", False, False, time.time() + 180
while time.time() < deadline:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    menus = buf.count(b"q pour annuler")
    if not sent_int and menus >= 1:
        time.sleep(1)
        os.killpg(os.getpgid(pid), signal.SIGINT)
        sent_int = True
    elif sent_int and not sent_q and menus >= 2:
        time.sleep(1)
        os.write(fd, b"q")
        sent_q = True
os.close(fd)
os.waitpid(pid, 0)
open(log_path, "wb").write(buf)
PYDRV

    ptylog="${WORK}/pty.log"
    # stty avant/après DANS le pty : c'est l'état du terminal du script qui est
    # en jeu, pas celui du shell de test.
    python3 "${WORK}/pty_driver.py" "$ptylog" \
        bash -c "stty -g > '${WORK}/tty.before'; '${TARGET}'; stty -g > '${WORK}/tty.after'" \
        >/dev/null 2>&1

    check "tty restauré à l'identique après Ctrl+C" "ok" \
        "$(cmp -s "${WORK}/tty.before" "${WORK}/tty.after" && echo ok || echo ko)"
    check "écho réactivé (pas de -echo résiduel)"    "ok" \
        "$(grep -q -- '-echo' "${WORK}/tty.after" && echo ko || echo ok)"
    check "interruption vue dans le pty"             "ok" \
        "$(grep -q 'Interruption (Ctrl+C)' "$ptylog" && echo ok || echo ko)"
    check "curseur réaffiché (ESC[?25h)"             "ok" \
        "$(grep -q $'\033\[?25h' "$ptylog" && echo ok || echo ko)"
    check "sortie propre par q"                      "ok" \
        "$(grep -q 'Sortie\.' "$ptylog" && echo ok || echo ko)"
else
    printf 'SKIP  python3 absent : test pty non exécuté\n'
fi

printf '\n'
if (( fails == 0 )); then
    printf 'RESULTAT: tous les cas OK\n'
else
    printf 'RESULTAT: %d cas en echec\n' "$fails"
fi
exit $(( fails > 0 ))
