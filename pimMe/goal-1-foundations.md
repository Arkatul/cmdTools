---
statut: à valider
maj: 2026-08-27
tags: [goal, script, pim, claude-code]
---
# Goal 1 — Squelette, auth check, parsing d'arguments, composant menu

## Contexte

Premier goal d'une série de 4 pour construire `pim-activate.sh`, un script bash interactif d'activation de rôles PIM Azure/Entra. Voir `plan.md` (même dossier) pour la vue d'ensemble et les décisions de design déjà actées. Ce goal ne doit PAS implémenter la logique métier PIM (listing, activation) — uniquement les fondations.

## Objectif

Livrer un script `pim-activate.sh` exécutable qui :

1. Vérifie la présence de `az` et `jq` dans le PATH ; message d'erreur clair et sortie non-zéro si l'un des deux manque.
2. Vérifie l'authentification via `az account show` ; si KO, message clair invitant à lancer `az login`, puis sortie non-zéro (pas de login automatique déclenché par le script).
3. Parse les arguments :
   - `-s`, `--scope` : valeurs autorisées `azure` | `entra`, défaut `azure` ; valeur invalide → message d'erreur et sortie non-zéro.
   - `-h`, `--help` : affiche l'usage et sort en 0.
4. Expose une fonction de menu interactif réutilisable (nom suggéré : `select_from_menu`) :
   - Entrée : un tableau bash de libellés (les options à afficher).
   - Affichage : liste numérotée, avec la ligne courante surlignée.
   - Navigation : flèches haut/bas pour déplacer la sélection, Entrée pour valider ; OU saisie directe d'un numéro suivi d'Entrée.
   - `q` annule le menu sans sélection (retour explicite exploitable par l'appelant, ex. code de sortie ou variable dédiée).
   - Retourne l'index (ou le libellé) sélectionné de façon exploitable par le reste du script.
   - Implémentation en bash pur (`read -rsn1`, séquences ANSI `\e[A` / `\e[B`), sans dépendance externe.

## Contraintes techniques

- `set -euo pipefail` en tête de script.
- Bash requis (tableaux, `read -rsn1`) — pas de compatibilité sh POSIX strict à viser.
- Fichier unique `pim-activate.sh`.
- En-tête de fichier en commentaire : usage, prérequis (`az` connecté, `jq`), description courte.

## Critères d'acceptation

- `./pim-activate.sh --help` affiche l'usage et sort en 0, sans appeler `az`.
- `./pim-activate.sh --scope invalide` sort en erreur avec message clair, sans appeler `az`.
- Sans authentification `az` valide, le script affiche une erreur claire et sort en non-zéro sans stack trace brute.
- La fonction de menu, testable isolément (bloc de test ou petit script séparé), permet de sélectionner un élément parmi 3-4 entrées factices, à la fois par flèches et par numéro, et gère `q` proprement.
- Aucune logique de listing ou d'activation PIM dans ce goal.

## Hors scope de ce goal

- Tout appel `az rest` vers ARM ou Microsoft Graph.
- Le flux de justification/activation.
- La boucle principale complète (assemblée dans `goal-4-main-loop.md`).
