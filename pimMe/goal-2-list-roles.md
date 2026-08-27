---
statut: à valider
maj: 2026-08-27
tags: [goal, script, pim, claude-code]
---
# Goal 2 — Listing des rôles PIM eligible (Azure + Entra) et switch de scope

## Contexte

Deuxième goal de la série `pim-activate.sh` (voir `plan.md`, même dossier). Part du squelette livré par `goal-1-foundations.md` (auth check, parsing d'arguments, composant `select_from_menu`) et y branche la récupération réelle des rôles eligible. Si `goal-1` n'a pas encore été exécuté dans ce projet, l'implémenter d'abord.

## Objectif

### 1. Azure resource roles (ARM)

- Récupérer l'objectId de l'utilisateur courant : `az ad signed-in-user show --query id -o tsv`.
- Identifier un scope racine du tenant (ex. management group racine via `az account management-group list` ou équivalent).
- Appel `az rest` GET sur :
  `https://management.azure.com/{scope}/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=2020-10-01&$filter=principalId eq '{principalId}'`
- Parser la réponse avec `jq` pour extraire, par rôle eligible : nom du rôle (peut nécessiter un lookup complémentaire sur `roleDefinitionId` si le nom n'est pas inclus), scope, et l'identifiant nécessaire à l'activation (`roleEligibilityScheduleId` ou équivalent présent dans la réponse).
- **Hypothèse de design (cf. plan.md)** : ce filtre sur un scope racine est censé cascader sur toutes les souscriptions. Si la réponse est vide ou incomplète en test réel, fallback = boucler sur `az account list --query "[].id" -o tsv` et interroger le même endpoint par souscription avec `$filter=asTarget()`. Documenter en commentaire de code le chemin effectivement retenu et pourquoi.

### 2. Entra ID directory roles (Graph)

- Appel `az rest` GET sur :
  `https://graph.microsoft.com/v1.0/roleManagement/directory/roleEligibilityScheduleInstances/filterByCurrentUser(on='principal')`
- Parser la réponse pour extraire : nom du rôle (`roleDefinition/displayName` si expand disponible, sinon lookup séparé sur `roleDefinitionId`), et l'identifiant nécessaire à l'activation (`id` de l'instance).

### 3. Affichage

- Construire la liste de libellés (nom du rôle + scope pour Azure) et l'afficher via `select_from_menu` (goal-1).
- Liste vide pour le scope courant → message clair (« Aucun rôle eligible sur ce scope »), pas de menu vide silencieux.

### 4. Switch de scope

- Depuis l'écran de liste, une touche dédiée bascule le scope courant (`a` = azure, `e` = entra) et rafraîchit la liste correspondante. Documenter le choix d'implémentation (extension de `select_from_menu` vs couche au-dessus).

## Contraintes techniques

- `jq` pour tout parsing JSON — pas de regex sur du JSON brut.
- Factoriser l'appel `az rest` commun (méthode, url, filtre) entre Azure et Entra si le pattern s'y prête.
- Chaque rôle listé doit porter avec lui toutes les infos nécessaires (roleDefinitionId, scope ou directoryScopeId, identifiant de la schedule eligible) pour que `goal-3-activation-flow.md` puisse construire la requête d'activation sans re-quêter l'API.

## Critères d'acceptation

- `./pim-activate.sh` (scope par défaut `azure`) affiche la liste réelle des rôles Azure eligible de l'utilisateur connecté (test manuel sur un tenant réel).
- `./pim-activate.sh --scope entra` affiche la liste réelle des rôles Entra eligible.
- Bascule de scope par touche fonctionnelle sans relancer le script.
- Liste vide gérée proprement.

## Hors scope de ce goal

- Le prompt de justification et la soumission d'activation (`goal-3-activation-flow.md`).
- La boucle de retour au menu après activation (`goal-4-main-loop.md`).
