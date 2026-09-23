# Vérification des performances — 23 septembre 2026

Périmètre : changements des 22 et 23 septembre, depuis le parent de `a50de60`
jusqu'à `5f273ef`, puis correctifs locaux des VH, guildes, calendrier et libellés.
Revue des chemins fréquents et de l'initialisation ; tests exécutés avec Lua 5.1.

## Corrections issues de la vérification

- Le classement des guildes inclut désormais tous les membres connus. Son tri
  utilise le tri coopératif existant, avec le même budget que le calcul du classement :
  64 unités de travail ou 1 ms par reprise. Le tableau ne crée que les lignes visibles.
- La revalidation des affiliations interroge les propriétaires joignables. Suppression
  des requêtes en double et des recherches de personnages hors ligne dans le réseau
  bêta. Une guilde déjà renseignée ne déclenche pas de diffusion générale pour sa
  seule revalidation. File limitée à 12 noms, lots de 6 et délai de 120 secondes par nom.
- La migration des anciens règlements de contrats vers le registre global participe
  maintenant au découpage de l'initialisation : 64 unités ou 1,25 ms par reprise.
  Les enregistrements et leurs règles de fusion sont conservés.

## Contrôles

| Chemin | Vérification |
| --- | --- |
| Classement | 10 000 joueurs, chacun dans une guilde distincte, plus 1 000 alias : totaux exacts, aucun tri synchrone de plus de 200 lignes, un seul callback en attente dans ce scénario. Au plus 192 recherches d'identité par reprise. |
| Actualisations répétées | 100 demandes successives réutilisent le constructeur en cours, pour les index comme pour l'affichage. |
| Réparation des guildes | Population déjà vérifiée : aucune requête. Rafale de 10 000 affiliations non vérifiées : 12 requêtes au maximum dans le lot en attente. |
| Archives de contrats | 5 000 règlements historiques migrés en 79 reprises, au plus 64 écritures par reprise, aucune perte. |
| Réseau bêta | Tests des routes, doublons, fragmentation, déconnexion d'un relais, file plafonnée à 128 paquets et budget partagé de 1 000 octets/s avec réserve maximale de 500 octets. |
| Rattrapage | Quatre clients, 180 lignes de VH et 120 de captures, trois sauts réseau et saturation : convergence et accusés de réception vérifiés. |
| Combat | Lecture du delta Blizzard et ajout groupé ; aucun parcours de la population ni timer par VH gagnée. |
| Interface et modules de la veille | Revue de la virtualisation du classement, des caches carte/minicarte, des actualisations regroupées du HUD et des noms, des limites réseau Général/contrats et des constructeurs de listes répartis sur plusieurs reprises. |

Les tests de charge sont dans `tests/forever_performance.test.lua` et exécutés par
les workflows de validation et de release. Les tests réseau et fonctionnels restent
séparés pour couvrir les résultats, et pas uniquement les limites de travail.

Ces résultats vérifient les bornes et la convergence du code. Ils ne mesurent pas
les FPS du client WoW : les budgets s'appliquent à chaque constructeur, plusieurs
callbacks peuvent partager une image, et les appels natifs ainsi que le rendu doivent
encore être profilés en jeu pendant une bataille. Aucune garantie de zéro saccade
ne peut être déduite du banc Lua seul.
