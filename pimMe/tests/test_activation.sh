#!/usr/bin/env bash
#
# tests/test_activation.sh — Tests du flux d'activation (pim-activate.sh, goal 3).
#
# Couvre tout ce qui est déterminable hors ligne : construction des corps de
# requête, décodage de la claim `oid`, lecture du statut de la demande, prompt
# de justification, diagnostic des erreurs az. Aucun appel réseau — la
# soumission réelle et le polling se valident sur un tenant (cf. goal 3).
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

# Jeu de données : un rôle Azure (scope ARM) et un rôle Entra (scope annuaire).
ROLE_LABELS=("Owner — subscription SandBox" "Global Reader — annuaire tenant")
ROLE_DEFINITION_IDS=(
    "/subscriptions/0000/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"
    "f2ef992c-3afb-46b9-b7cf-a126ee74c451"
)
ROLE_SCOPES=("/subscriptions/0000" "/")
ROLE_SCHEDULE_IDS=(
    "/subscriptions/0000/providers/Microsoft.Authorization/roleEligibilitySchedules/abcd"
    "sched-entra-1"
)

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

printf '\n=== Corps de requête Entra (Graph) ===\n'

body="$(_entra_activation_body 1)"
check "JSON valide"                       "ok" "$(jq -e . >/dev/null 2>&1 <<<"$body" && echo ok || echo ko)"
check "action selfActivate"               "selfActivate" "$(jq -r '.action' <<<"$body")"
check "directoryScopeId depuis ROLE_SCOPES" "/" "$(jq -r '.directoryScopeId' <<<"$body")"
check "roleDefinitionId nu (pas de chemin ARM)" "${ROLE_DEFINITION_IDS[1]}" "$(jq -r '.roleDefinitionId' <<<"$body")"
# Graph refuse la casse ARM : afterDuration, pas AfterDuration.
check "expiration.type camelCase"         "afterDuration" "$(jq -r '.scheduleInfo.expiration.type' <<<"$body")"
check "pas d'enveloppe properties"        "null" "$(jq -r '.properties // "null"' <<<"$body")"

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

SCOPE="azure"
check "ARM : .properties.status"  "Provisioned" "$(_request_status <<<'{"properties":{"status":"Provisioned"}}')"
check "ARM : statut absent"       ""            "$(_request_status <<<'{"properties":{}}')"
SCOPE="entra"
check "Graph : .status"           "Granted"     "$(_request_status <<<'{"status":"Granted","id":"x"}')"
SCOPE="azure"

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
check "durée refusée par la politique" "ok" "$(diagnose 'RoleAssignmentRequestPolicyValidationFailed' | grep -q 'DEFAULT_DURATION_HOURS' && echo ok || echo ko)"
check "détail brut toujours affiché" "ok" "$(diagnose 'Erreur inconnue XYZ' | grep -q 'Erreur inconnue XYZ' && echo ok || echo ko)"

printf '\n'
if (( fails == 0 )); then
    printf 'RESULTAT: tous les cas OK\n'
else
    printf 'RESULTAT: %d cas en echec\n' "$fails"
fi
exit $(( fails > 0 ))
