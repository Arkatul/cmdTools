---
statut: à valider
maj: 2026-08-27
tags: [goal, script, pim, claude-code]
---
# Goal 3 — Justification, soumission de l'activation, polling du statut

## Contexte

Troisième goal de la série `pim-activate.sh` (voir `plan.md`, même dossier). Part du principe qu'un rôle a été sélectionné via le flux livré par `goal-2-list-roles.md`, avec toutes les infos nécessaires (roleDefinitionId, scope/directoryScopeId, identifiant de la schedule eligible, scope courant azure|entra). Si `goal-1`/`goal-2` n'ont pas encore été exécutés dans ce projet, s'appuyer sur leur code existant plutôt que de le redévelopper.

## Objectif

### 1. Prompt de justification

- Afficher un champ de saisie pré-rempli d'un placeholder « business » modifiable (ex. `Intervention support — troubleshooting`), édité en place par l'utilisateur avant validation.
- Ne jamais soumettre le placeholder sans confirmation explicite : Entrée valide le texte affiché à l'écran, y compris s'il n'a pas été modifié par l'utilisateur.

### 2. Soumission — Azure (ARM)

- `PUT https://management.azure.com/{scope}/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/{guid}?api-version=2020-10-01` (GUID généré via `uuidgen` ou équivalent disponible en bash).
- Body attendu : `principalId`, `roleDefinitionId`, `requestType: SelfActivate`, `justification`, `scheduleInfo` (`startDateTime` = maintenant, `expiration` = `{type: AfterDuration, duration: PT{N}H}` avec N = `DEFAULT_DURATION_HOURS` défini dans `plan.md`), et `linkedRoleEligibilityScheduleId` si l'API le retourne en erreur comme requis (à vérifier en test, l'ajouter si nécessaire).

### 3. Soumission — Entra (Graph)

- `POST https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignmentScheduleRequests`.
- Body attendu : `action: selfActivate`, `principalId`, `roleDefinitionId`, `directoryScopeId`, `justification`, `scheduleInfo` (même logique de durée que pour Azure).
- Si l'appel échoue avec une erreur liée au MFA/claims (HTTP 403, message mentionnant MFA ou claims challenge), afficher un message explicite : le rôle nécessite une session MFA fraîche, suggérer de relancer `az login` puis de réessayer. Ne pas faire planter le script.

### 4. Polling du statut

- Après soumission, poll GET sur la ressource créée (`roleAssignmentScheduleRequests/{guid}` côté ARM, `roleAssignmentScheduleRequests/{id}` côté Graph) toutes les 3-5 secondes environ.
- États à distinguer à l'affichage :
  - `Provisioned` → succès, sortie de boucle.
  - `Failed` / `Cancelled` → échec, afficher le message d'erreur renvoyé par l'API si présent.
  - `PendingApproval` → afficher l'état, sortir du polling après un timeout (60s, cf. plan.md) sans gérer le workflow d'approbation.
- Indicateur d'attente simple pendant le polling (spinner ou points qui s'accumulent).

## Critères d'acceptation

- Sur un rôle Azure eligible réel, activation de bout en bout jusqu'à `Provisioned` visible dans le portail PIM.
- Sur un rôle Entra eligible réel, soit activation de bout en bout, soit message d'erreur MFA explicite si la session ne le permet pas — les deux issues sont acceptables pour ce goal, le comportement doit juste être clair et ne pas planter.
- Justification jamais soumise sans passage explicite par le prompt, même avec le placeholder par défaut inchangé.
- Timeout de polling respecté sur un rôle configuré avec approbation (si disponible pour test) — pas de boucle infinie.

## Hors scope de ce goal

- La boucle de retour au menu de listing après l'activation (`goal-4-main-loop.md`).
- Le listing lui-même (déjà couvert par `goal-2-list-roles.md`, réutilisé tel quel en entrée).
