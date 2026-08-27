# pim-activate.sh

Activation interactive de rôles PIM **de ressources Azure**, en alternative au
portail : lister ses rôles éligibles, en activer un après justification, suivre
le provisionnement, enchaîner — sans quitter le script.

Le chemin Entra ID (rôles d'annuaire via Microsoft Graph) a été retiré : le
script ne parle qu'à l'API ARM.

## Prérequis

- `bash` 4+, `jq`, `az` (Azure CLI) avec une session ouverte (`az login`) ;
- `uuidgen` facultatif (repli sur `/proc/sys/kernel/random/uuid`).

Le script ne déclenche jamais de `az login` : il constate et informe.

## Utilisation

```
./pim-activate.sh [-s|--scope azure] [-h|--help]
```

`--help` détaille options, navigation, règle de justification et limitations.

Dans la liste : flèches ou numéro pour choisir, `Entrée` pour activer, `r` pour
recharger, `q` pour quitter, `Ctrl+C` pour annuler la saisie ou l'attente en
cours sans quitter.

## Exemple d'exécution

Session réelle (deux activations enchaînées, sortie par `q`) :

```
$ ./pim-activate.sh
Connecté en tant que ADM_XXX@example.be (tenant bb2cf736-…).
Chargement des rôles eligible (scope azure)…
Rôles azure eligible (19) — Entrée active, r recharge, q quitte :
   1) Contributor  —  managementgroup MG-Brucity
   …
> 16) Reader  —  managementgroup Tenant Root Group
   17) User Access Administrator  —  subscription LZ-CPAS
Flèches haut/bas + Entrée, numéro + Entrée, q pour annuler : (r)

Rôle sélectionné :
  libellé              : Reader  —  managementgroup Tenant Root Group
  roleDefinitionId     : /providers/…/roleDefinitions/acdd72a7-…
  scope                : /providers/Microsoft.Management/managementGroups/bb2cf736-…
  schedule eligible    : /providers/…/roleEligibilitySchedules/66701712-…

Justification (Entrée valide, ligne vide annule) : Validation goal 4 - premier role du cycle

Soumission de la demande (8h)…
Attente du provisionnement .
Rôle activé (Provisioned) pour 8h.
Chargement des rôles eligible (scope azure)…            ← retour automatique
Rôles azure eligible (19) — Entrée active, r recharge, q quitte :
…
17
Rôle sélectionné :
  libellé              : User Access Administrator  —  subscription LZ-CPAS
  …
Rôle sensible (User Access Administrator) :
justification obligatoire, aucun texte n'est pré-rempli.
Justification obligatoire (Ctrl+C annule) :
Erreur : Justification obligatoire pour ce rôle : saisissez un motif (Ctrl+C pour annuler).
Justification obligatoire (Ctrl+C annule) : Revue des acces LZ-CPAS - demande utilisateur

Soumission de la demande (8h)…
Attente du provisionnement .
Rôle activé (Provisioned) pour 8h.
Chargement des rôles eligible (scope azure)…
Rôles azure eligible (19) — Entrée active, r recharge, q quitte :
q
Sortie.
$ echo $?
0
```

### Justification

Une justification pré-remplie et modifiable est proposée. Sur **Owner** et
**User Access Administrator**, elle devient obligatoire : rien n'est pré-rempli
et une ligne vide est refusée — un placeholder validé d'un coup d'`Entrée` ne
documente rien, et c'est sur ces deux rôles que la trace doit être réelle.

### Erreurs et interruptions

Un appel `az` qui échoue (réseau coupé, droits manquants, politique PIM, rôle
déjà actif) est traduit en message actionnable, suivi du détail brut, puis
ramène à la liste :

```
Soumission de la demande (8h)…
Erreur : Échec de la soumission de l'activation Azure.
Erreur : Appel Azure impossible : le réseau ou le service ne répond pas.
Erreur : Vérifiez la connectivité (proxy, VPN, DNS) puis rechargez la liste.
ERROR: HTTPSConnectionPool(host='management.azure.com', port=443): Max retries exceeded…
Chargement des rôles eligible (scope azure)…
```

Si la liste elle-même ne peut plus être chargée, le script demande
`Recharger la liste ? [O/n]` plutôt que de boucler indéfiniment.

`Ctrl+C` pendant la saisie ou le polling revient à la liste, terminal rendu
intact (échos et curseur restaurés) ; une demande déjà soumise continue d'être
traitée côté Azure et reste consultable dans le portail.

## Tests

```
bash tests/test_menu.sh         # menu : navigation, saisie, annulation, hotkeys
bash tests/test_activation.sh   # corps de requête, justification, diagnostics
bash tests/test_interrupt.sh    # Ctrl+C réel (signal au groupe) + état du tty
```

`test_interrupt.sh` émet de vrais appels `az` (session ouverte requise) et
utilise `python3` pour le pty ; il n'active aucun rôle.

## Limitations connues

- pas de désactivation d'un rôle actif (passer par le portail) ;
- workflow d'approbation non géré : une demande `PendingApproval` est affichée
  puis abandonnée après 60 s de polling, sans être annulée ;
- mono-tenant : celui de la session `az` courante ;
- rôles d'annuaire Entra ID non gérés.
