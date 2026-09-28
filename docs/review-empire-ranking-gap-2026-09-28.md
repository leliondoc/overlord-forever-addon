# Écart EMPIRE entre les deux factions

Revue en lecture seule du 28 septembre 2026, avec deux agents Sol6 spécialisés.
L'utilisateur confirme que les deux clients sont à jour, ont rechargé l'interface
et que les captures sont proches dans le temps.

## Mesures disponibles

Les captures affichent 36 331 HK côté Horde contre 70 973 côté Alliance pour
EMPIRE, soit 34 642 HK d'écart. Les différences individuelles vont dans les deux
sens : Il Blasfemo 4 443 / 4 140 ; Leat Shadowshot 3 352 / 3 352 ; Fethi Wap
3 274 / 3 201. Aucun des deux clients ne constitue donc à lui seul une référence
complète démontrée.

La sauvegarde locale Overlord.lua, datée du 28/09 à 16:53:19, contient :

- 1 048 joueurs avec un score ; tous figurent dans le snapshot local.
- EMPIRE : 88 joueurs avec un score, tous Alliance, somme brute 70 947.
- Cache d'affichage EMPIRE : 70 942 ; snapshot : 70 942.
- 41 membres EMPIRE confirmés par le propriétaire : 28 921 HK.
- 47 autres membres : 42 026 HK. Une seule de ces lignes a guildAt=0,
  pour 100 HK. L'absence de confirmation ne prouve pas une attribution fausse.
- Les membres EMPIRE présents parmi les 500 meilleurs joueurs totalisent
  70 734 HK. La queue au-delà de ce rang ne représente que 213 HK.

Ces mesures excluent un simple doublement graphique et le plafond des 5 000
joueurs comme explication locale. Elles ne prouvent pas que 70 947 soit le bon
total. Le fichier est une sauvegarde sur disque, pas une lecture de la mémoire
des deux clients au moment des captures.

## Défaut de convergence des appartenances

Leaderboard.lua:1612-1628 additionne les scores de campagne des joueurs dont la
guilde actuellement connue correspond au groupe. Ce n'est pas un historique des
kills gagnés pendant l'appartenance à cette guilde : changer la guilde connue
déplace le score de campagne entier.

Leaderboard.lua:3567-3595 refuse un changement de guilde par un LK provenant
d'un tiers dès qu'une guilde non vide est renseignée, même avec une date plus
récente. Sync.lua ne traite pas les LK relayés comme une déclaration du
propriétaire. Un test ciblé de la fusion reproduit la conservation d'une ancienne
guilde après un LK tiers plus récent ; une déclaration du propriétaire la corrige.

Les recherches de guilde tentent de contacter le propriétaire. Les réponses
indirectes GY ne remplacent pas non plus une guilde déjà renseignée. La réception
complète des pages v6 ne garantit donc pas l'égalité des appartenances ni des
totaux de guilde. Lever indistinctement ce contrôle exposerait le classement à
des changements de guilde falsifiés.

## Retard possible du rattrapage complet

SyncHistoryCatchup.lua:952 réserve le démarrage v6 à une manche de classement
seul. La première manche territoriale utilise v4. La préférence pour la manche
v6 suivante, posée à la ligne 1509, reste en mémoire seulement : un /reload peut
la perdre avant le réveil suivant si aucun ACK historique n'est conservé.

Le code autorise 270 secondes sans réponse et 1 200 secondes si une réponse
partielle n'aboutit pas, jusqu'à quatre tentatives. Le rattrapage complet peut
donc être retardé de nombreuses minutes malgré une version à jour. Ces valeurs
sont des délais du code, pas des durées observées pendant les captures.

Dans la sauvegarde examinée, leaderboardHistoryCatchupAck est absent et les
checkpoints ont encore l'ancien format sans version ni stream. Cela ne démontre
pas une passe v6 récente ; cela ne prouve pas non plus l'état de la session en
cours après le dernier chargement. Les diagnostics /ov network permettent de
vérifier la manche active et la progression réelle.

## Ce qui reste nécessaire pour attribuer exactement l'écart

Comparer la sauvegarde Overlord.lua côté Horde, pour la même campagne, membre
par membre : présence du joueur, score, guilde, date et provenance de cette
appartenance. Cela distinguera les scores manquants des scores rangés sous une
autre guilde. Aucun score ni aucune sauvegarde n'a été modifié pendant la revue.

Les tests ciblés existants guild_totals, display_cache et performance passent.
Ils ne prouvent pas la convergence réelle entre les deux sessions de jeu.

## Comparaison directe avec Retail

Référence examinée : `_retail_/Interface/AddOns/Overlord` sur cette machine.
Cette comparaison ne date pas les changements des mois de mai à juillet.

- Retail, Leaderboard.lua:3562-3585 : les appartenances reçues par LK sont
  fusionnées selon leur date et un départage déterministe, y compris lorsqu'une
  guilde est déjà renseignée. Forever, Leaderboard.lua:3567-3595 : le contrôle
  supplémentaire de provenance empêche ce remplacement pour les tiers. C'est
  une différence de convergence, pas seulement une différence de transport.
- Retail, SyncAux.lua:2711 et suivantes : la communauté fournit un annuaire
  des membres en ligne utilisés comme destinataires de whispers. Aucun journal
  serveur de messages communautaires relu pour ce rattrapage n'a été trouvé.
  Les sauvegardes des joueurs restent les répliques persistantes.
- Le transport et l'ordonnancement du rattrapage Forever diffèrent : découverte
  des pairs et relais Battle.net/canal, cadence réduite, limites de files,
  première manche historique avant les pages complètes. L'existence d'un pont
  ne prouve donc ni la livraison complète ni l'adoption des données.

### Signalement supplémentaire : domination

Captures : 52,72 % Alliance côté Horde contre 67,88 % Alliance côté Alliance,
soit 15,16 points. La fusion réseau courante de SyncDomination.lua conserve
essentiellement la règle Retail : sélectionner une photographie complète selon
un ordre déterministe. Le problème des guildes ne s'applique pas à cette barre.

Une migration propre à Forever, Core.lua:3665-3694, réunit les anciens pools en
prenant le maximum de chaque champ numérique séparément. Elle peut fabriquer
une photographie qui n'existait dans aucun pool : (A=800,H=200) et (A=200,H=800)
deviennent (A=800,H=800), total 1 600 au lieu de 1 000. Le rapprochement réseau
normal privilégie le total le plus élevé ; une telle valeur peut donc persister.
C'est une différence de code concrète avec Retail, mais rien dans les captures
seules ne prouve que cette migration explique les deux pourcentages signalés.
