# Forteresses : moteur commun avec les avant-postes

## Comportement

Les cinq forteresses conservent leurs emplacements, leurs icônes de bâtiment
principal et leur colonne dédiée dans le classement. Leur capture utilise
désormais Outpost / OutpostControl : disponibilité permanente, contestation,
décroissance en quittant la zone, reprise par la faction adverse et possession
jusqu'à une reprise ou au reset de campagne. La durée de base est de 600 secondes,
contre 300 pour les avant-postes ; les mêmes règles de réduction s'appliquent.

La colonne Forteresses compte les captures, avec le même registre et les mêmes
règles de déduplication que les avant-postes. Elle reste distincte de leur colonne.

## Suppression de l'ancien système

GuildKeepControl.lua, GuildKeepImmersion.lua et SyncGuildKeep.lua sont supprimés.
GuildKeep.lua ne conserve que l'adaptation de présentation pour les icônes,
infobulles et sélecteurs existants. GuildKeepSites.lua contient les emplacements.
SyncStrategicSites.lua conserve la validation commune des expéditeurs et WB
(bonus de ressources), toujours utilisés indépendamment des anciennes forteresses.

Les horaires de siège, autorités et témoins spécifiques, rappels et récompenses
quotidiennes n'ont plus de contrôleur, producteur réseau ou récepteur actif.
GK / GC / GA / GH / G7 sont exclus du relais. Les forteresses passent par OP / OC
et le rattrapage commun LO / LOC / OE. Une demande SR d'un ancien client ne
déclenche donc plus de production des preuves quotidiennes GH.

Au premier chargement, Outpost:EnsureDB supprime les champs SavedVariables
`guildKeep*` et pose le marqueur `fortressOutpostSchema`. Les forteresses repartent
neutres et leur ancien classement quotidien est supprimé, conformément à la
demande. Les états et scores existants des avant-postes sont conservés. Aucun
fichier SavedVariables du jeu en cours n'a été édité.

Les anciens clients ne connaissent pas les nouveaux sites de forteresse dans OP.
Ils doivent être mis à jour pour participer à ce fonctionnement. Leurs anciens
messages de siège ne recréent pas les données supprimées chez un client mis à jour.

## Vérification locale

- 60 suites Lua 5.1 et 17 tests Node passent.
- Test dédié : cinq sites, durée, capture, abandon, ancien propriétaire restauré,
  sauvegarde/rechargement, icônes, absence de doubles marqueurs, migration,
  séparation des classements et reset de campagne.
- Réception réelle OP / LOC sur une base d'observateur vierge : état partagé,
  durée de 600 s et répétition sans ajout de captures.
- Le contrôle des reprises reçues utilise la durée minimale du site concerné.
- Le relais refuse les cinq anciens types avant admission, sans livraison ni
  éviction de trafic utile. Le rejeu SR utilise une seule liste de sites OP.

## Mesure en jeu encore nécessaire

Le client resté connecté pendant les modifications exécute l'ancien Lua.
La référence avant rechargement montre 19 109 envois, 3 295 drops cumulés,
GH à 507,4 Ko et 1 340 refus/drops, et DX/VB à 24/24 places. La dernière
observation initiale du total Horde est 104 435, annoncé immobile pendant vingt minutes.
Le rattrapage V5 affichait encore 61 pages et 684 lignes, interrompu.

Ces observations ne mesurent pas le nouveau code. Après rechargement, vérifier
les deux colonnes, les captures et les alertes, puis comparer `/ov network` après
quelques minutes. La suppression des flux de siège réduit leur charge à la
source ; elle ne démontre pas à elle seule que la saturation DX/VB ou le blocage
du classement Horde sont résolus.

Observation supplémentaire avant rechargement : Horde progresse ensuite à
104 441 (+6). À 74 minutes, le relais affiche 23 363 envois, 15 981 réceptions et
6 333 drops ; GH représente 517,9 Ko, 2 122 admissions et 2 250 refus/drops.
Le V5 reste interrompu à 684 lignes. L'historique legacy indique 12 lignes reçues
et aucune requête terminée. Cela confirme des arrivées intermittentes, sans
démontrer que le classement est rattrapé.

Pas de publication ni de changement de version
effectués dans cette intervention.
