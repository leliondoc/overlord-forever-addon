# Audit de fidélité Classic / Retail — 28 septembre 2026

## Périmètre et méthode

Comparaison du code local Overlord Forever 1.1.3 avec Overlord Retail 9.9.40.
Trois agents GPT-6 Sol examinent les cartes et le transport, le classement et la
persistance, puis les alertes et événements ; l'agent principal reproduit les
défauts de priorité et vérifie l'intégration. Retail reste en lecture seule.
Les modifications préexistantes du répertoire Classic sont conservées.
Révision de départ : `3be3bcac1e47b65d42c74d4bf6a741ea172b1621`, avec modifications locales.

Les tests utilisent le code Lua de production et Lua 5.1 (Lupa), avec horloges,
réseau et API WoW simulés. Ils vérifient les invariants et certains délais sous
charge contrôlée ; ils ne mesurent pas le délai réel des serveurs Blizzard.
Avant les corrections de cet audit : 38 fichiers de tests Lua passent et les
17 vérifications Node passent. Les défauts ci-dessous nécessitaient de nouveaux
scénarios de régression.

## Défauts reproduits et corrections

### Carte globale rejetée après une connexion sans sauvegarde

L'initialisation ne donnait leurs propriétaires de base qu'aux capitales du front
actif. Les autres capitales apparaissaient comme neutres dans le snapshot global,
ce qui invalidait tout le lot chez son destinataire. La réception indépendante
d'un timer ZS restait possible : un assaut visible ne prouvait pas que la carte
avait été récupérée.

Les capitales absentes sont maintenant initialisées après restauration, à l'epoch
de campagne ou du reset de leur front. Une capture existante ou un assaut en cours
n'est pas remplacé par cette valeur de base. Le test `forever_map_login.test.lua`
charge les sept fronts, simule un assaut sur Blackrock Advance et applique un vrai
lot ZA chez un destinataire neuf. Ce correctif précédait le présent audit et a
été conservé et revérifié.

### Fin de capture refusée derrière les mises à jour de progression

Une file contenant 112 messages ZS de progression refusait un nouveau C, même si
ce dernier annonçait la fin d'une capture. L'ancien mécanisme d'éviction ne savait
reprendre une place que dans la file ordinaire ou l'excédent de rattrapage.

C, ZS terminal, ZR, GC, GA, OC, TV et FR ont maintenant priorité sur les progressions en attente. Une
fin peut remplacer un ancien heartbeat ou ZS de progression dont l'envoi n'a pas
commencé. Les limites globales, les fragments commencés et les engagements de
barricade restent protégés. L'ordre des événements terminaux reste FIFO.
`forever_beta_terminal_priority.test.lua` échouait avant correction ; dans son
scénario à un pont Battle.net, les trois événements finaux passent en moins de
deux secondes malgré une file pleine. Ce chiffre est propre à cette simulation.
Le même scénario vérifie l'admission des fins de fortin/avant-poste, victoire et
reset, livrées en moins de cinq secondes dans cette simulation.

### Requête de carte et pages ZA refusées malgré la réserve de rattrapage

SR et ZA ciblés utilisaient la file ordinaire. À 112 progressions en attente,
ils étaient refusés alors que seize places restaient réservées au classement.
Un rattrapage de carte avec une route connue utilise désormais cette réserve et
son budget partagé. Deux places supplémentaires sont accessibles au producteur
local lorsque le classement occupe déjà les seize places : à la limite globale
de 128, elles remplacent uniquement des présences ou progressions non commencées.
Il réessaie les pages refusées via le ticker SR existant. Les relais intermédiaires
peuvent protéger jusqu'à 32 messages SR/ZA adressés : limiter aussi ces relais à
deux places faisait encore perdre des pages d'un lot accepté en amont.

La protection est attachée au message et survit aux changements d'ordre dans la
file. Le service alterne au plus quatre messages de carte puis un de classement,
dans le budget inchangé de 1 000 octets/s, dont 300 garantis au rattrapage.

Une cible sans route fraîche garde le comportement ordinaire. Les tests
`forever_beta_map_catchup_queue.test.lua` et
`forever_beta_map_ranking_contention.test.lua` vérifient l'admission, les bornes,
la protection contre l'éviction et la livraison. Avec 112 progressions et 16 HB
de taille comparable aux messages de production, SR et ZA passent en moins de
20 secondes dans la simulation, et les 16 HB arrivent également. Le délai du
producteur de réponse SR tient désormais compte du nombre de pages ZA à envoyer
(20 secondes plus 6 secondes par page, maximum 212 secondes), avec un watchdog
cohérent. Un scénario supplémentaire fait passer 32 ZA et 16 HB sur un chemin long
avec des progressions continues : la dernière ZA arrive à 73,2 secondes et le
dernier HB à 87,3 secondes, dans le TTL inchangé de 120 secondes des paquets.
Ces chiffres décrivent les simulations, pas une mesure de latence en jeu.

### Gros message accepté puis perdu pendant l'assemblage

L'assemblage expirait quinze secondes après le premier fragment. Un message
synthétique de 3,48 Ko, accepté par le transport, peut prendre davantage avec
la part garantie de 300 octets/s pendant que les progressions occupent le reste
du débit. Le dernier fragment arrivait donc après destruction du début du message.
Ce test pousse la limite du transport : les pages de classement v5/v6 de production
sont déjà découpées en messages HB de 250 octets au maximum. Il ne démontre donc
pas que ces pages habituelles subissaient cette expiration.

L'expiration dépend désormais de trente secondes sans nouveau fragment, avec une
borne totale de 120 secondes et les bornes de nombre/taille inchangées. Les
doublons n'allongent pas l'inactivité. Le test
`forever_beta_fragment_expiry.test.lua` reproduit le défaut sous 110 progressions en
attente puis vérifie la réception complète.

### Rattrapage des alertes de guilde : comptabilité du simulateur

La nouvelle alerte de guilde, absente de Retail, dispose d'un simulateur de
diagnostic. Celui-ci retirait des entrées temporaires sans diminuer leur compteur,
ce qui faussait progressivement la limite de 512 joueurs. La suppression maintient
maintenant ce compteur. `forever_alert_transport_audit.test.lua` vérifie 120
simulations successives et le passage de K Battle.net directs vers l'alerte.
Les nouvelles notifications GW peuvent être relayées pour informer les autres
joueurs ; elles ne constituent pas une preuve autorisant à recréditer des kills.
GW reste un message informatif de priorité ordinaire : le test de saturation
confirme qu'une fin de capture peut reprendre sa place dans la file.

### Confirmation tardive d'une capture proche de 100 %

Le poll observateur lançait surtout une demande générale dont les répondants
sont tirés au sort sur le réseau bêta. Le producteur de la capture était pourtant
connu par le bail ZS. De plus, le poll de fin attendait 100 % affichés, alors que
l'affichage peut se figer à 477/480 lorsque les dernières mises à jour manquent.

Le poll cible maintenant d'abord l'origine connue par une route bêta fraîche,
puis conserve le filet général. Le contrôle existe aussi dans le vrai chemin
public de `SyncAux.lua`, qui surcharge le helper de `Sync.lua`, et dans le poll
d'état périmé. Une progression à moins de cinq secondes de la fin peut demander
confirmation après le délai monotone attendu, même si son affichage est figé.
Il s'agit d'une demande : elle ne transforme jamais le timer en capture acquise.
`forever_observer_terminal_catchup.test.lua` vérifie 477/480, l'absence de relance
prématurée, une origine relayée connue, le rejet d'une cible inconnue et le fallback.

### Classement affiché plus large que son rattrapage

Classic affiche jusqu'à 500 joueurs de capture par faction, mais le snapshot
reprenait la limite Retail de 25, adaptée à son affichage plus court. Le protocole
v5 ne paginait que les kills ; les captures et les races dépendaient des petites
tranches v4, respectivement 75 et 40 lignes. Un transfert considéré terminé
pouvait donc laisser des positions du classement Classic absentes.

Le snapshot conserve maintenant 500 lignes de capture par faction, et le protocole
v6 pagine séparément les kills (LK), les captures (LC) et les races (LR). Le checkpoint
persisté retient le flux et le bucket à reprendre. La réussite globale n'est
annoncée qu'après le dernier flux. Un ancien pair v5 conserve son rattrapage de
kills puis le fallback v4 pour les autres données ; il ne certifie pas une
récupération v6 complète.

La liste des objectifs capturés était aussi tronquée à 32 identifiants et 120
octets dès la construction du snapshot. La borne est portée à 128 identifiants
validés et 3 000 octets par joueur. Les lignes LC v6 sont assemblées dans des pages
d'au plus 4 064 octets, transmises par fragments de 170 octets de données. La
sérialisation v4 garde son format court pour les anciens clients.

Une autre perte concernait les alias : le score était dédoublonné sous le nom
canonique, mais ses zones étaient copiées uniquement depuis cette clé. Les zones
restées sous un ancien nom disparaissaient du snapshot. Une passe découpée indexe
maintenant les listes par identité et en fait l'union pour les joueurs retenus.
Le test répartit les 59 objectifs entre deux alias et les retrouve tous à l'arrivée.

`audit_ranking_v6.test.lua` vérifie le rang 500, les races au-delà du rang 40,
59 objectifs conservés chez le destinataire, trois sauts réseau, la déduplication
des alias, une seconde ronde identique, le rejet d'une page du mauvais flux,
l'interruption/reprise du flux LC après rechargement, et le fallback v5/v4.

## Vérifications supplémentaires des événements

`forever_event_replay_audit.test.lua` passe par les handlers de production : DX
restaure les totaux absolus d'un front sans doubler un replay ; VB restaure un
bonus associé à une victoire persistée sans l'ajouter deux fois ; une victoire
récente reste rejouable ; les appenders SR couvrent les états des six fortins et
des sept avant-postes, y compris les états neutres à propager.

`forever_event_multihop_audit.test.lua` complète cette vérification par le vrai
transport BetaNetwork sur trois sauts jusqu'aux handlers DX/VB de production.
Les totaux et le bonus arrivent ; une nouvelle enveloppe contenant les mêmes
événements traverse de nouveau les ponts sans les créditer une seconde fois.

Les fixtures Retail suivantes passent directement contre le code Classic :
`wb_ledger_runtime.lua`, `outpost_ledger_slice_runtime.lua`,
`login_barrier_intent_runtime.lua` et `sync_kill_dedup_runtime.lua`.
Deux autres ont dû être interprétées, et non comptées comme réussies telles quelles :

- `victory_bonus_projection_runtime.lua` attend le pool `eu` dans ses stubs,
  son stockage et ses payloads. Classic utilise `global`. Après adaptation de
  ces hypothèses dans une copie temporaire, le scénario de 8 000 événements et
  519 reprises passe.
- `guild_keep_proof_ledger_runtime.lua` reconstruit bien la preuve attendue,
  mais sa comparaison littérale attend `eu` au lieu de `global`. Adapter cette
  seule attente fait passer la fixture complète.

La fixture extraite `sr_full_snapshot_runtime.lua` n'est pas directement portable :
son environnement synthétique ne fournit pas `PrepareSnapshotForNetwork`, utilisé
par Classic. Ce résultat n'est ni un succès de test ni une preuve de panne du jeu.

## Contrats conservés

- Les noms complets Forever remplacent les identités Retail avec royaume.
- Une réponse ciblée peut emprunter un pont Battle.net ; le demandeur n'a pas
  besoin d'être lui-même ami du capteur adverse.
- Sans communauté, le canal de faction permet la découverte locale ; les ponts
  Battle.net étendent les pairs joignables à l'autre faction. Le canal ne conserve
  pas d'historique : un nouvel arrivant récupère les états conservés par les pairs
  encore joignables, y compris un allié ayant reçu une carte adverse auparavant.
- Un timer observé ne devient pas une capture locale à 100 %. Une confirmation
  C, ZS terminal ou ZA validée reste nécessaire.
- Les scores ne sont pas crédités à une identité antérieure simplement déclarée
  par un relais. L'alerte de guilde consomme les K directs validés, pas l'historique
  LK ni des K réémis comme nouveaux événements. La notification informative GW
  dispose d'un chemin distinct ; sa réception ne modifie pas le score.
- Les campagnes, timestamps, dédoublonnages, budgets réseau et limites mémoire
  demeurent contrôlés. Une reprise ne doit pas recréditer une capture ou un bonus.

## Limites de la conclusion

Un audit et des simulations ne garantissent pas un réseau sans perte ni une
latence identique à Retail. Le graphe de ponts doit être connecté et au moins un
pair doit conserver la donnée. Une donnée perdue chez tous les pairs, notamment
si la bêta ne recharge aucune SavedVariable, ne peut pas être reconstruite.
La communauté Retail fournit une liste de destinataires directement joignables ;
Forever doit découvrir des chemins, et plusieurs échanges peuvent partager le
même pont. La compatibilité avec les anciennes versions conserve nécessairement
leurs limites tant qu'elles n'ont pas été mises à jour.

La réserve de 32 cartes est partagée par tous les échanges SR/ZA du relais, sans
réservation distincte par snapshot. Les essais prouvent la livraison d'un lot
complet sous la charge décrite, pas celle de plusieurs lots maximaux simultanés
ou de plusieurs relais saturés consommant ensemble plus que le TTL d'un paquet.

La vue réseau du classement reste volontairement bornée : 5 000 lignes de kills,
500 lignes de capture par faction, et 128 objectifs/3 000 octets par joueur.
L'audit ne promet pas la récupération des données dépassant ces bornes. Les
politiques locales de validation, niveau ou blacklist peuvent aussi conduire à
filtrer une ligne reçue ; « transfert reçu » ne garantit pas des copies identiques
chez des clients configurés différemment.

La borne de plausibilité héritée de Retail refuse les totaux de captures
supérieurs ou égaux à 500. Elle n'a pas été assouplie : un tel total local ne peut
pas être restauré par LC dans cette version. Le rang 500 testé désigne la position
du joueur dans le classement, pas un total de 500 captures.

Les alertes GW sont transitoires, sans journal durable ni accusé de réception.
Elles peuvent céder leur place à une fin de capture sous saturation ; l'audit ne
garantit donc pas que chaque notification informative arrive.

Les captures d'écran montrent un état bloqué près de la fin puis une convergence
avec une trêve déjà entamée. Les défauts de file et de rattrapage reproduits peuvent
expliquer ce type de délai ; sans trace réseau de la session, ils ne prouvent pas
à eux seuls quel paquet exact avait manqué dans cette capture.

## Validation en jeu restante

Validation automatisée finale : **47 fichiers de tests Lua 5.1 réussis, 17 tests
Node réussis, 55 fichiers Lua de production compilés sans erreur**. Le test de
performance couvre 10 000 joueurs et 1 000 alias ; la préparation reste découpée
en tranches et les files conservent leurs bornes. Les nouveaux tests figurent
dans les workflows de validation et de release. `git diff --check` est propre.

Après chargement du correctif chez les participants et les ponts, tester une
connexion tardive pendant un assaut de capitale, puis une fin de capture avec un
rattrapage de classement en cours. Comparer la carte, la trêve, les captures et les
scores des deux factions. Refaire après `/reload`, interruption d'un pont et retour
du pont. Les diagnostics `/ov network` permettent d'observer les refus et le
rattrapage, sans confondre une valeur historique récupérée avec une nouvelle alerte.
