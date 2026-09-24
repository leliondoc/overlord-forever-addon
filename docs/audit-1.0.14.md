# Audit de publication 1.0.14 — 24 septembre 2026

## Périmètre et résultat

Trois agents GPT-6 Luna ont examiné les changements depuis 1.0.13 : performance, filtrage/synchronisation, données/localisations. Relecture et validations finales par l'agent principal.

- **Performance :** aucun nouveau traitement par image identifié. Les nouveaux objectifs ajoutent des entrées fixes aux registres existants. Le cadre vide du panneau est créé une seule fois ; sa construction complète reste différée.
- **Filtrage :** les six fronts participent à la validation des identifiants. Les messages concernant le fortin supprimé des Carmines sont refusés par le registre des sites actifs. Les anciennes lignes de sauvegarde ne réactivent pas ce fortin.
- **Données et langues :** guide disponible dans les sept langues, six fronts, cinq fortins et deux avant-postes indépendants cohérents avec les registres. Les fichiers ptBR et zhCN complètent les noms des 57 objectifs. Le nom personnalisé « Aeythyr Lodge » reste volontairement identique dans toutes les langues, selon la demande de l'auteur.

## Corrections issues de l'audit

- Night Run : 72.5/50 décrivait un virage d'accès. Centre corrigé à 66.6/56, avec référence indépendante du camp à 66.6/57.
- Mystral : maintien du point terrestre à 50.84/75.08, conformément au nom « rive sud », à distance du refuge de Vent-argent.
- Test des captures étendu de 40 à 57 références, avec les identifiants Classic et leurs alias pour les deux nouveaux fronts. La provenance et les limites des références sont décrites dans `forever-capture-locations.md`.

## Vérifications locales finales

- 25 contrôles Lua 5.1 natif : syntaxe des 52 fichiers Lua et 24 suites fonctionnelles, tous réussis. Cela couvre notamment les limites de charge, la synchronisation bêta, les scores, les captures, les ressources, les sièges, les sauvegardes, les pop-ups et la position du panneau après rechargement.
- 14 tests Node réussis, dont les registres Forever et la cohérence des versions de publication.
- Chargement réel des sept localisations sous Lua 5.1 : 821 chaînes et 57 noms d'objectifs par langue. Vérification des signatures de formatage ; les pourcentages littéraux du guide sont insérés comme texte, sans `string.format`.
- `git diff --check` réussi. Les données privées de `_local`, les tests et les documents sont exclus du paquet par la configuration de publication.

L'audit automatisé ne remplace pas une session en jeu : le relief, le rendu réel des polices et la restauration du cache natif propre au client bêta n'ont pas été certifiés sur un client connecté.
