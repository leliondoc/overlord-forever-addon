# Revue des modifications parallèles — 28 septembre 2026

## Périmètre

Revue du diff local non committé par rapport à `3be3bca` et des nouveaux fichiers,
notamment `GuildKillAlert.lua`. Trois agents GPT-6 Sol ont revu indépendamment les
alertes, l'interface/classement et les sièges/objectifs. L'agent principal a vérifié
l'intégration réseau et reproduit l'injection d'une notification GW.

Le diff contient aussi les correctifs de notre audit Retail précédent. Git ne
permet pas d'attribuer avec certitude chaque ligne non committée à Claude ou à un
autre auteur ; les constats portent sur le code actuellement présent.

Cette passe est une revue : aucun code de production n'a été modifié. Les défauts
ci-dessous restent donc présents. Les reproductions utilisent les modules Lua de
production avec les horloges et API WoW simulées, sans envoyer de messages en jeu.

## Constats à corriger

### 1. P1 — Le pont entre factions ne suffit pas à déclencher l'alerte de raid

**Code :** `GuildKillAlert.lua:294`, `Sync.lua:3549`, `SyncBetaNetwork.lua:754`.

Le détecteur ignore immédiatement les kills de sa propre faction. Or le réseau
ne retransmet pas les K de proche en proche, et le receveur refuse à juste titre
les K dont l'auteur ne peut pas être authentifié directement.

Dans la topologie normale « raid Horde → relais Horde → ami Battle.net Alliance
→ canal Alliance », les clients Horde voient les kills authentifiés des cinq
membres, mais ne les comptent pas pour GW. Le relais Alliance ne voit directement
que son ami Horde, donc au plus un des cinq auteurs requis. Aucun détecteur
n'atteint le seuil ; aucune notification GW n'est produite.

**Reproduction :** 20 kills par cinq membres de la faction locale produisent
zéro alerte et zéro envoi planifié. Le relais adverse, avec un seul auteur direct,
reste également à zéro. Le test existant utilise cinq amis Battle.net directs
dans la même guilde, une situation qui contourne ce défaut.

**Correction recommandée :** séparer l'agrégation et la diffusion des observations
authentifiées de l'affichage réservé à la faction ennemie. Ne pas autoriser des K
relayés à créditer les scores. Si les deux factions sont agrégées, indexer les
guildes au minimum par faction et nom, car la clé actuelle est seulement le nom.

### 2. P2 — Une fausse notification réseau peut masquer la vraie pendant dix minutes

**Code :** `Sync.lua:2951–2955`, `GuildKillAlert.lua:385–421`.

Le chemin GW accepte un message addon direct sans contrôler que son auteur est
un pair reconnu ou une source autorisée. Le paramètre `sender` n'est jamais utilisé
par le handler ; la validation porte sur la forme du payload et ses chiffres.

**Reproduction :** appel du vrai `OnAddonMessage` avec le préfixe `OverlordF`,
le canal `WHISPER`, un auteur inconnu et un GW valide dans sa forme. Une alerte
« 20 kills / 5 membres » est affichée. Une vraie détection locale ultérieure pour
la même guilde reste silencieuse, car le faux GW a armé son cooldown.

Cela ne modifie pas le classement. Cela permet néanmoins une fausse alerte et la
suppression temporaire d'une information utile. La limite de quatre affichages
par minute ne résout pas cette attribution.

**Correction recommandée :** définir et vérifier la provenance autorisée de GW,
et séparer la réception d'une déclaration distante de la suppression d'une
détection locale corroborée. Un simple contrôle de format n'atteste pas les kills.

### 3. P2 — Le reset hebdomadaire peut bloquer le détecteur

**Code :** `GuildKillAlert.lua:73–107`.

Le compteur précédent est conservé comme un maximum, sans epoch de campagne.
Après le reset, un nouveau total inférieur à l'ancien ne produit aucun delta,
mais rafraîchit malgré tout la date de la référence.

**Reproduction :** cinq joueurs avaient un total de 100 ; après changement de
campagne, leurs nouveaux totaux passent de 1 à 20. Le module ne compte aucun de
ces kills et ne planifie aucun GW.

Le blocage dure jusqu'au dépassement de l'ancien total ou à une absence complète
de K pendant 900 secondes. Recevoir régulièrement des K peut donc prolonger le
problème bien au-delà de quinze minutes.

**Correction recommandée :** rattacher les références, fenêtres d'événements et
envois différés à l'epoch du score. Ne pas traiter toute baisse arbitraire comme
un reset, car des messages plus anciens peuvent arriver dans le désordre.

### 4. P2 — Des kills observés sur dix minutes sont annoncés comme récents sur cinq

**Code :** `GuildKillAlert.lua:23–25`, `GuildKillAlert.lua:75–82`,
`GuildKillAlert.lua:312`.

La fenêtre affichée vaut 300 secondes, mais le delta utilise une référence vieille
de jusqu'à 900 secondes. Tout le saut du compteur est daté de la réception du
dernier message.

**Reproduction :** cinq membres sont observés à 1 kill, puis à 5 kills dix minutes
plus tard, sans messages intermédiaires. Le module affiche 20 kills en cinq minutes,
alors que ces observations ne permettent pas de dater les 20 kills dans cette fenêtre.

**Correction recommandée :** ne pas attribuer à la fenêtre courante un delta dont
le point de départ la précède. À défaut d'horodatages des événements intermédiaires,
reprendre une référence prudente au lieu d'inventer leur récence.

### 5. P2 — Désactiver l'option ne supprime pas un envoi déjà programmé

**Code :** `GuildKillAlert.lua:347–371`.

Une détection planifie un GW 0,5 à 6 secondes plus tard. Le callback et `Broadcast`
ne relisent pas `IsEnabled()`.

**Reproduction :** détecter un raid, désactiver l'option avant l'expiration du délai,
puis exécuter le callback : un GW part quand même.

**Correction recommandée :** revérifier l'option et la génération/epoch au moment
de l'envoi, ou invalider les callbacks lors de la désactivation.

### 6. P2 — Le guide flottant peut rester sur l'ancien objectif

**Code :** `ZoneIndicator.lua:649–663`, `Core.lua:6127–6133`.

Le nouvel affichage flottant peut viser un objectif `available`. Le garde de
rafraîchissement périodique renvoie alors `false` tant que le joueur ne capture pas.
Il ne vérifie pas si un autre objectif disponible est devenu le plus proche.

**Reproduction :** afficher A avec l'option activée ; faire retourner B par le vrai
sélecteur d'objectif alors que A reste disponible. Le garde reste à `false`, et le
tick du Core n'appelle plus `RefreshHud`. Les tests existants rafraîchissent
directement l'indicateur et ne passent pas par cette condition périodique.

**Correction recommandée :** permettre la resélection périodique lorsque la cible
affichée est un guide `_guidance`, en gardant la cadence bornée existante.

### 7. P2 — Une guilde historique peut être attribuée à un K sans guilde actuelle

**Code :** `GuildKillAlert.lua:302–305`.

En l'absence de tag de guilde dans le K, le détecteur reprend directement la guilde
du cache du classement, sans vérifier sa fraîcheur. Le classement peut conserver
une ancienne attribution quand le K ne transporte aucun registre de guilde daté.

**Reproduction :** cinq lignes de classement contiennent `FormerGuild` ; cinq
auteurs authentifiés envoient des K avec un tag de guilde vide et un timestamp de
guilde nul. Les totaux 1 puis 4 déclenchent une alerte attribuée à `FormerGuild`.
Le receveur ne dispose pourtant d'aucune confirmation de cette appartenance actuelle.

**Correction recommandée :** distinguer guilde absente, guilde explicitement vide
et information historique. N'utiliser le cache que si sa validité actuelle est
établie ; sinon éviter cette attribution dans une alerte en temps réel.

## Observations secondaires

- Le cooldown GW est uniquement en mémoire. Le même payload peut s'afficher de
  nouveau après `/reload`, pendant sa fenêtre de validité de cinq minutes.
- L'éviction du cache de 64 guildes peut retirer un cooldown récent : le scénario
  d'une alerte puis de 64 autres guildes permet une deuxième alerte avant dix minutes.
- La simulation restaure la valeur effective de l'option, mais transforme une
  valeur par défaut `nil` en `true`. Aucun trafic réseau de simulation n'a été observé.

Ces points ne créditent pas de score supplémentaire ; ils concernent les garanties
d'affichage, de cooldown ou de restauration exacte des préférences.

## Autres changements examinés

| Ensemble | Résultat de la revue |
| --- | --- |
| Classement à 500 captures, aperçu disque à 25, tri découpé, recherche et virtualisation | Pas de nouveau défaut confirmé dans ces changements ; tests affichage, recherche et performance réussis. |
| Réglages, hauteur de défilement, option flottante, remise par défaut, commandes | Intégration examinée ; les problèmes différés d'alerte et de guide sont décrits ci-dessus. |
| TOC et ordre de chargement | Locales avant GuildKillAlert, module disponible avant les consommateurs UI ; aucun défaut confirmé. |
| GuildKeep / SyncGuildKeep | Cache de seconde et décalage horaire, retour de l'horloge et dédoublonnage examinés ; tests sièges et récompenses réussis. |
| FrontLocales et traductions modifiées | Champs et correspondances présents ; aucun nouveau défaut confirmé par cette revue. |
| Synchronisation carte/classement ajoutée lors de l'audit précédent | Correctifs conservés ; validation de non-régression globale réussie. |
| Workflows et tests ajoutés | Les tests de l'audit précédent sont intégrés aux deux workflows. Les nouveaux scénarios de cette revue révèlent des comportements non couverts. |

## Validation

Les **47 fichiers de tests Lua existants passent** sur l'état revu. Les agents ont
aussi exécuté les tests ciblés de classement, de performances à 10 000 joueurs,
de sièges et d'objectifs ; les fichiers UI/locales examinés compilent sous Lua 5.1.
`git diff --check` est propre.

Les reproductions supplémentaires révèlent les défauts ci-dessus malgré cette
suite verte. Il faut en faire des tests de non-régression lors des corrections.
Cette revue ne constitue pas une validation dans le client WoW connecté.
