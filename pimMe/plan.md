---
statut: à valider
maj: 2026-08-27
tags: [plan, script, pim, azure, entra]
---
# Plan — pim-activate.sh

## Contexte

Script bash interactif d'activation de rôles PIM (Azure resource roles + Entra ID directory roles), pensé comme alternative rapide au portail. Découpé en 4 goals séquentiels, chacun conçu pour être donné tel quel en prompt de démarrage d'une session Claude Code.

## Décisions de design retenues

- **Listing Azure** : filtre `principalId eq {objectId}` sur un scope racine (management group racine du tenant) plutôt qu'une boucle par souscription — un seul appel cascade sur toute la hiérarchie. **Hypothèse à valider** en test réel ; si résultat vide/incomplet, fallback = boucle sur `az account list`.
- **Navigation menu** : composant bash pur (pas de dépendance externe type `fzf`), support flèches haut/bas + Entrée ET saisie directe du numéro + Entrée.
- **Durée d'activation** : le script utilise la durée max exposée par l'API si disponible, sinon une constante `DEFAULT_DURATION_HOURS` (8h par défaut) en tête de script. **Hypothèse à ajuster** selon la politique PIM réelle du tenant.
- **Approval workflow** (`PendingApproval`) : non géré en v1. Le script affiche l'état et sort du polling après un timeout (60s), retour au menu.
- **MFA sur activation Entra** : risque connu (l'API peut exiger une claim MFA fraîche). Le script détecte l'erreur et affiche un message explicite plutôt que de planter.

## Séquencement

1. `goal-1-foundations.md` — squelette, dépendances (`az`, `jq`), check auth, parsing des arguments, composant de menu interactif réutilisable.
2. `goal-2-list-roles.md` — récupération et affichage des rôles PIM eligible (Azure ARM + Entra Graph), switch de scope par lettre.
3. `goal-3-activation-flow.md` — prompt de justification, soumission de la demande d'activation, polling du statut.
4. `goal-4-main-loop.md` — boucle principale complète, gestion d'erreurs globale, documentation finale du script.

L'ordre est important : chaque goal dépend du résultat du précédent. Valider (test manuel sur un tenant réel) avant de passer au suivant.

## Hors scope (rappel, tous goals confondus)

- Désactivation d'un rôle actif.
- Gestion du workflow d'approbation.
- Multi-tenant.

## Sources techniques (MS Learn)

- Activate my Azure resource roles in PIM — https://learn.microsoft.com/entra/id-governance/privileged-identity-management/pim-resource-roles-activate-your-roles
- Create roleAssignmentScheduleRequests (Graph) — https://learn.microsoft.com/graph/api/rbacapplication-post-roleassignmentschedulerequests
- unifiedRoleEligibilityScheduleInstance: filterByCurrentUser — https://learn.microsoft.com/graph/api/unifiedroleeligibilityscheduleinstance-filterbycurrentuser
- az account get-access-token (résolution de token, fallback) — https://learn.microsoft.com/cli/azure/account