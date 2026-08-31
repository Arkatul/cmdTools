---
statut: à valider
maj: 2026-08-27
tags: [goal, script, pim, claude-code]
---
# Goal 4 — Intégration finale : boucle principale, gestion d'erreurs globale, doc

## Contexte

Dernier goal de la série `pim-activate.sh` (voir `plan.md`, même dossier). Assemble `goal-1-foundations.md` (squelette/menu), `goal-2-list-roles.md` (listing) et `goal-3-activation-flow.md` (activation) en un flux complet et robuste. S'appuyer sur le code déjà produit par ces trois goals plutôt que de le redévelopper.

## Objectif

### 1. Boucle principale

- Après une activation (succès, échec, ou annulation via `q` depuis le menu de sélection de rôle), retour automatique à l'écran de liste des rôles eligible du scope courant, rafraîchie.
- Depuis l'écran de liste : sélectionner un rôle relance le flux de justification/activation (`goal-3`) ; switcher de scope (`a`/`e`) rafraîchit la liste correspondante ; `q` quitte proprement le script (code de sortie 0).

### 2. Gestion d'erreurs globale

- Toute erreur `az rest` non gérée spécifiquement par `goal-2`/`goal-3` (timeout réseau, erreur HTTP inattendue) doit être interceptée, affichée de façon lisible (pas de stack trace `set -e` brute), et ramener l'utilisateur à l'écran de liste plutôt que de crasher le script entier.
- `Ctrl+C` en cours de polling ou de saisie doit être intercepté proprement (trap) et ramener au menu plutôt que de laisser un état de terminal incohérent (ex. curseur invisible après un `read -rsn1` interrompu).

### 3. Documentation finale

- En-tête de script complet : usage (`-h`/`--help` détaillé avec exemples), prérequis, description courte du fonctionnement, limitations connues (pas de désactivation, pas de gestion d'approbation, mono-tenant — cf. `plan.md`, section « hors scope »).
- Un exemple d'exécution en commentaire ou dans un `README.md` séparé si plus lisible ainsi — choix libre, à documenter dans la PR/commit.

## Critères d'acceptation

- Session complète manuelle : lancer le script, activer un rôle, revenir à la liste, switcher de scope, activer un autre rôle, quitter avec `q` — sans redémarrer le script entre chaque étape.
- Une erreur réseau simulée (ex. couper la connexion pendant un appel `az rest`) ne fait pas planter le script : message clair, retour au menu.
- `Ctrl+C` pendant le polling ramène proprement au menu de liste, sans sortie brutale ni terminal cassé.
- `--help` à jour et complet, cohérent avec le comportement réel du script.

## Hors scope de ce goal

- Toute nouvelle fonctionnalité non prévue dans les goals 1 à 3 (désactivation de rôle, gestion du workflow d'approbation, multi-tenant — cf. `plan.md`).
