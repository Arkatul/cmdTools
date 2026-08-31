#!/usr/bin/env bash
#
# tests/test_activation.sh — Tests du flux d'activation et de la boucle
# principale (pim-activate.sh, goals 3 et 4).
#
# Couvre tout ce qui est déterminable hors ligne : construction du corps de
# requête, décodage de la claim `oid`, lecture du statut de la demande, prompt
# de justification (régime standard et régime obligatoire), règle des rôles
# sensibles, drapeau d'interruption, relance après échec. Aucun appel réseau —
# la soumission réelle et le polling se valident sur un tenant (cf. goal 3/4).
#
# Usage :
#   bash tests/test_activation.sh
#
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TEST_DIR}/../pim-activate.sh"

# shellcheck source=../pim-activate.sh
source "$TARGET"
# pim-activate.sh pose `set -euo pipefail` en se sourçant : on relâche -e, le
# harnais teste justement des retours non-zéro.
set +e

fails=0

check() {
    local label="$1" expected="$2" got="$3"
    if [[ "$got" == "$expected" ]]; then
        printf 'PASS  %-48s -> %s\n' "$label" "$got"
    else
        printf 'FAIL  %-48s -> attendu "%s", obtenu "%s"\n' "$label" "$expected" "$got"
        fails=$((fails + 1))
    fi
}

# Jeu de données : trois rôles Azure — un sensible reconnu par GUID, un
# sensible reconnu par nom seul, un ordinaire.
ROLE_LABELS=(
    "Owner — subscription SandBox"
    "User Access Administrator — subscription SandBox"
    "Reader — subscription SandBox"
)
ROLE_DEFINITION_IDS=(
    "/subscriptions/0000/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    "/subscriptions/0000/providers/Microsoft.Authorization/roleDefinitions/99999999-9999-9999-9999-999999999999"
    "/subscriptions/0000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
)
ROLE_SCOPES=("/subscriptions/0000" "/subscriptions/0000" "/subscriptions/0000")
ROLE_SCHEDULE_IDS=(
    "/subscriptions/0000/providers/Microsoft.Authorization/roleEligibilitySchedules/abcd"
    "/subscriptions/0000/providers/Microsoft.Authorization/roleEligibilitySchedules/efgh"
    "/subscriptions/0000/providers/Microsoft.Authorization/roleEligibilitySchedules/ijkl"
)
ROLE_NAMES=("Owner" "User Access Administrator" "Reader")

AZ_PRINCIPAL_ID="11111111-2222-3333-4444-555555555555"
# Volontairement piégeuse : guillemets, apostrophe, accents, backslash.
JUSTIFICATION='Incident "P1" — l'"'"'accès prod\test'

printf '=== Corps de requête Azure (ARM) ===\n'

body="$(_azure_activation_body 0 "")"
check "JSON valide"                       "ok"    "$(jq -e . >/dev/null 2>&1 <<<"$body" && echo ok || echo ko)"
check "requestType"                       "SelfActivate" "$(jq -r '.properties.requestType' <<<"$body")"
check "principalId = utilisateur"         "$AZ_PRINCIPAL_ID" "$(jq -r '.properties.principalId' <<<"$body")"
check "roleDefinitionId"                  "${ROLE_DEFINITION_IDS[0]}" "$(jq -r '.properties.roleDefinitionId' <<<"$body")"
check "justification échappée telle quelle" "$JUSTIFICATION" "$(jq -r '.properties.justification' <<<"$body")"
check "expiration.type"                   "AfterDuration" "$(jq -r '.properties.scheduleInfo.expiration.type' <<<"$body")"
check "duration = DEFAULT_DURATION_HOURS" "PT${DEFAULT_DURATION_HOURS}H" "$(jq -r '.properties.scheduleInfo.expiration.duration' <<<"$body")"
check "startDateTime au format ISO UTC"   "ok" "$(jq -r '.properties.scheduleInfo.startDateTime' <<<"$body" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo ok || echo ko)"
check "linked absent par défaut"          "null" "$(jq -r '.properties.linkedRoleEligibilityScheduleId // "null"' <<<"$body")"

body="$(_azure_activation_body 0 "${ROLE_SCHEDULE_IDS[0]}")"
check "linked présent au 2e essai"        "${ROLE_SCHEDULE_IDS[0]}" "$(jq -r '.properties.linkedRoleEligibilityScheduleId' <<<"$body")"

printf '\n=== Claim oid du jeton ARM ===\n'

# Payload base64url sans padding, avec un `_` et un `-` dans le corps encodé.
make_jwt_payload() {
    printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='
}
check "oid extrait"        "$AZ_PRINCIPAL_ID" "$(_jwt_oid "$(make_jwt_payload "{\"oid\":\"$AZ_PRINCIPAL_ID\",\"upn\":\"a@b.c\"}")")"
check "padding à 2 restitué" "abc"            "$(_jwt_oid "$(make_jwt_payload '{"oid":"abc","x":"1"}')")"
check "claim absente -> vide" ""              "$(_jwt_oid "$(make_jwt_payload '{"upn":"a@b.c"}')")"
check "payload illisible -> vide" ""          "$(_jwt_oid 'pas-du-base64!!')"

printf '\n=== Statut de la demande ===\n'

check "ARM : .properties.status"  "Provisioned" "$(_request_status <<<'{"properties":{"status":"Provisioned"}}')"
check "ARM : statut absent"       ""            "$(_request_status <<<'{"properties":{}}')"

printf '\n=== GUID de demande ===\n'

guid="$(new_request_guid)"
check "format uuid minuscule" "ok" "$(grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' <<<"$guid" && echo ok || echo ko)"
check "deux appels diffèrent"  "ok" "$([[ "$guid" != "$(new_request_guid)" ]] && echo ok || echo ko)"

printf '\n=== Prompt de justification ===\n'
# Hors terminal, readline est désactivé : -i ne pré-remplit pas. C'est
# précisément le contrat testé ici — seul le texte réellement validé compte.

# Redirection par substitution de processus et NON par pipe : un pipe placerait
# prompt_justification dans un sous-shell, où l'écriture de $JUSTIFICATION
# serait perdue — exactement ce que le passage par variable globale évite.

JUSTIFICATION="sentinelle"
prompt_justification < <(printf '  Intervention support  \n') >/dev/null 2>&1
check "texte saisi, espaces rognés" "Intervention support" "$JUSTIFICATION"

JUSTIFICATION="sentinelle"
prompt_justification < <(printf '\n') >/dev/null 2>&1; rc=$?
check "ligne vide -> annulation"    "$MENU_CANCELLED" "$rc"
check "ligne vide -> rien à soumettre" "" "$JUSTIFICATION"

JUSTIFICATION="sentinelle"
prompt_justification < /dev/null >/dev/null 2>&1; rc=$?
check "EOF -> annulation"           "$MENU_CANCELLED" "$rc"
check "EOF -> rien à soumettre"     "" "$JUSTIFICATION"

printf '\n=== Rôles à justification obligatoire ===\n'

check "Owner (GUID intégré)"        "ok" "$(justification_is_mandatory 0 && echo ok || echo ko)"
check "User Access Administrator (nom)" "ok" "$(justification_is_mandatory 1 && echo ok || echo ko)"
check "Reader ordinaire"            "ko" "$(justification_is_mandatory 2 && echo ok || echo ko)"

# Nom absent de l'API : le GUID doit suffire, et inversement.
saved_names=("${ROLE_NAMES[@]}")
ROLE_NAMES=("" "" "")
check "Owner sans displayName"      "ok" "$(justification_is_mandatory 0 && echo ok || echo ko)"
check "UAA sans displayName ni GUID connu" "ko" "$(justification_is_mandatory 1 && echo ok || echo ko)"
ROLE_NAMES=("${saved_names[@]}")

# Casse et espaces : le nom vient de l'API, on ne suppose rien.
ROLE_NAMES[2]="OWNER"
check "nom insensible à la casse"   "ok" "$(justification_is_mandatory 2 && echo ok || echo ko)"
ROLE_NAMES[2]="Reader"

printf '\n=== Prompt de justification obligatoire ===\n'

# Rôle sensible : rien de pré-rempli (prefill vide) et refus des lignes vides.
JUSTIFICATION="sentinelle"
prompt_justification 0 < <(printf 'Escalade incident P1\n') >/dev/null 2>&1; rc=$?
check "rôle sensible : texte accepté" "0" "$rc"
check "rôle sensible : texte retenu"  "Escalade incident P1" "$JUSTIFICATION"

# Deux lignes vides puis un motif : les vides sont refusées, la saisie continue.
# Sortie capturée dans un FICHIER et non par substitution : un sous-shell
# perdrait l'écriture de $JUSTIFICATION (cf. note plus haut).
out_file="$(mktemp)"
JUSTIFICATION="sentinelle"
prompt_justification 0 < <(printf '\n   \n Motif réel \n') >"$out_file" 2>&1; rc=$?
check "rôle sensible : vides refusées puis motif" "0" "$rc"
check "rôle sensible : motif rogné"   "Motif réel" "$JUSTIFICATION"
check "rôle sensible : refus signalé" "2" "$(grep -c 'Justification obligatoire pour ce rôle' "$out_file")"

# Jamais de placeholder soumis en douce : sur EOF sans saisie, rien ne part.
JUSTIFICATION="sentinelle"
prompt_justification 0 < /dev/null >/dev/null 2>&1; rc=$?
check "rôle sensible : EOF -> annulation" "$MENU_CANCELLED" "$rc"
check "rôle sensible : rien à soumettre"  "" "$JUSTIFICATION"

# Le placeholder du régime standard ne doit pas fuiter dans le régime strict.
prompt_justification 0 < <(printf 'X\n') >"$out_file" 2>&1
check "rôle sensible : pas de placeholder affiché" "0" "$(grep -c "$DEFAULT_JUSTIFICATION" "$out_file")"
check "rôle sensible : mention obligatoire"        "1" "$(grep -c 'justification obligatoire' "$out_file")"
rm -f "$out_file"

printf '\n=== Interruption (Ctrl+C) ===\n'

INTERRUPTED=0
check "drapeau au repos"            "1" "$(take_interrupt; echo $?)"
INTERRUPTED=1
check "drapeau levé -> consommé"    "0" "$(take_interrupt; echo $?)"
INTERRUPTED=1
take_interrupt
check "consommation remet à zéro"   "0" "$INTERRUPTED"
check "code distinct de l annulation" "ok" \
    "$([[ "$ACTIVATION_INTERRUPTED" != "$MENU_CANCELLED" && "$ACTIVATION_INTERRUPTED" -lt 128 ]] && echo ok || echo ko)"

printf '\n=== Relance après échec de listing ===\n'

check "Entrée -> recharge"          "0" "$(prompt_retry_or_quit < <(printf '\n') >/dev/null 2>&1; echo $?)"
check "o -> recharge"               "0" "$(prompt_retry_or_quit < <(printf 'o\n') >/dev/null 2>&1; echo $?)"
check "n -> quitte"                 "1" "$(prompt_retry_or_quit < <(printf 'n\n') >/dev/null 2>&1; echo $?)"
check "q -> quitte"                 "1" "$(prompt_retry_or_quit < <(printf 'q\n') >/dev/null 2>&1; echo $?)"
check "EOF -> quitte (pas de boucle infinie)" "1" "$(prompt_retry_or_quit < /dev/null >/dev/null 2>&1; echo $?)"

printf '\n=== Périmètre : entra retiré, --scope retiré ===\n'

# Le périmètre n'est plus un choix : plus de flag, plus de variable, plus de
# validateur. Ce qui reste à vérifier, c'est qu'aucune trace ne subsiste.
check "aucune option --scope"       "0" \
    "$(grep -c -e '--scope' -e '\-s|' "$TARGET")"
check "aucun validate_scope"        "ko" \
    "$(declare -f validate_scope >/dev/null 2>&1 && echo ok || echo ko)"
check "aucune variable SCOPE"       "0" \
    "$(grep -c '^SCOPE=' "$TARGET")"
check "aucune URL Graph dans le script" "0" \
    "$(grep -c 'graph\.microsoft\.com' "$TARGET")"
check "aucune soumission Entra"     "ko" \
    "$(declare -f submit_entra_activation >/dev/null 2>&1 && echo ok || echo ko)"

printf '\n=== Diagnostic des erreurs az ===\n'

AZ_REST_ERROR_FILE="$(mktemp)"
trap 'rm -f "$AZ_REST_ERROR_FILE"' EXIT
AZ_TENANT_ID="bb2cf736-0000-0000-0000-000000000000"

diagnose() {
    printf '%s\n' "$1" > "$AZ_REST_ERROR_FILE"
    explain_az_error 2>&1
}
check "consentement Graph manquant" "ok" "$(diagnose 'ERROR: PermissionScopeNotGranted' | grep -q 'permissions Graph' && echo ok || echo ko)"
check "session expirée (AADSTS70043)" "ok" "$(diagnose 'SubError: token_expired AADSTS70043: refresh token expired' | grep -q 'Session Azure CLI expirée' && echo ok || echo ko)"
check "rappel du tenant dans az login" "ok" "$(diagnose 'AADSTS70043' | grep -q "$AZ_TENANT_ID" && echo ok || echo ko)"
check "MFA requis"                  "ok" "$(diagnose 'AADSTS50076: due to a configuration change made by your administrator' | grep -q 'authentification forte' && echo ok || echo ko)"
check "rôle déjà actif"             "ok" "$(diagnose 'ERROR: Bad Request({"error":{"code":"RoleAssignmentExists","message":"The Role assignment already exists."}})' | grep -q 'déjà actif' && echo ok || echo ko)"
check "durée refusée par la politique" "ok" "$(diagnose 'RoleAssignmentRequestPolicyValidationFailed' | grep -q 'DEFAULT_DURATION_HOURS' && echo ok || echo ko)"
check "détail brut toujours affiché" "ok" "$(diagnose 'Erreur inconnue XYZ' | grep -q 'Erreur inconnue XYZ' && echo ok || echo ko)"
# Panne réseau : le message doit rester lisible et parler connectivité.
check "réseau injoignable (DNS)"    "ok" "$(diagnose "urllib3 ... Failed to establish a new connection: [Errno -3] Temporary failure in name resolution" | grep -q 'réseau ou le service ne répond pas' && echo ok || echo ko)"
check "réseau injoignable (timeout)" "ok" "$(diagnose 'HTTPSConnectionPool(host=management.azure.com): Read timed out. (read timeout=300)' | grep -q 'réseau ou le service ne répond pas' && echo ok || echo ko)"

printf '\n'
if (( fails == 0 )); then
    printf 'RESULTAT: tous les cas OK\n'
else
    printf 'RESULTAT: %d cas en echec\n' "$fails"
fi
exit $(( fails > 0 ))
