# Convergence Retail adaptée aux relais Forever

## Objectif et périmètre

Retrouver les règles de rapprochement des données de Retail sans dépendre de
l'annuaire communautaire inter-faction. Les paquets passent par le canal de
faction, les groupes et les ponts Battle.net existants. La communauté Retail
servait d'annuaire de pairs en ligne ; son code ne relisait pas un journal
central stocké par Blizzard pour reconstituer le classement.

Ces changements s'ajoutent aux corrections précédentes de rattrapage des cartes,
de priorité des fins de capture et de reprise des pages. Ils ne réinitialisent
pas les scores des joueurs. Aucun fichier SavedVariables n'a été édité pendant
l'intervention ; l'addon persistera ses nouveaux marqueurs normalement en jeu.

## Classement

- Un snapshot LK sollicité et admis par le rattrapage peut corriger une guilde
  plus ancienne, y compris lorsque le propriétaire est hors ligne. Les départs
  de guilde sont transmis comme des registres vides horodatés.
- Entre observations directes et snapshots admis, la date puis un départage
  stable déterminent le résultat. L'ordre d'arrivée ne décide plus de la guilde.
- La provenance locale `guildReplica` survit aux sauvegardes, reconstructions
  d'index et fusions d'alias. Elle ne prétend pas authentifier le propriétaire.
  Les LK spontanés restent soumis aux restrictions antérieures.
- Le classement paginé commence avant la longue manche d'historique au premier
  rattrapage. Après sa réussite, un marqueur de campagne conservé au reload
  laisse à l'historique son tour. Un transfert partiel reprend son checkpoint.
- Une limitation anti-rafale pendant l'application d'une page diffère la ligne
  au lieu de la compter comme traitée. Après 30 secondes de blocage, la session
  s'interrompt en conservant le bucket à reprendre.

La confiance d'un snapshot reste celle du pair sollicité et du protocole
existant : il ne s'agit pas d'une preuve cryptographique des scores ou de la
guilde. Les contrôles de campagne, niveau, identité, expéditeur et transport
restent actifs.

## Domination

- La migration des anciens pools choisit une photographie complète par front
  selon l'ordre de fusion DX. Elle ne fabrique plus `max(Alliance)+max(Horde)`
  à partir de deux photographies différentes.
- Un bonus VB reçu avant sa preuve TV peut attendre dans un cache borné à
  64 candidats pendant deux heures. Il n'est crédité qu'après les validations
  existantes. Les doublons ne prolongent pas son expiration.
- Une preuve TV ou une mise à jour DX peut relancer la validation. Le calcul
  VB dépendant de tous les fronts, un DX d'un autre front peut aussi débloquer
  un candidat. Un seul worker traite au maximum quatre candidats par passage,
  avec au plus un callback en attente. Les doublons ne créditent jamais deux
  fois le même événement.
- DX/VB disposent d'un service réservé dans la file des relais, pour que les
  rafales de progression des captures ne les repoussent pas indéfiniment.

## Bornes réseau et travail par frame

Le budget des relais reste partagé : 1 000 octets estimés par seconde, avec un
burst de 500 octets, en comptant chaque copie canal/groupe/Battle.net. Les voies
de rattrapage et d'état prélèvent leur part dans ce budget ; elles ne créent pas
de budgets supplémentaires. La file globale reste limitée à 128 paquets.
L'admission préserve 24 places pour DX/VB, 16 pour le rattrapage ancien et
4 pour les échanges paginés v5/v6, avec 84 places ordinaires. Le rattrapage
ancien peut emprunter des places ordinaires sans consommer les 24 places
d'état ni les 4 places paginées. Le service d'état utilise 250 octets/s du
budget partagé, et le rattrapage 300 octets/s de ce même budget.

Le producteur paginé attend dès que quatre paquets v5/v6 sont en file. Les
requêtes et accusés de réception passent avant les pages, puis le service
alterne les pages paginées et anciennes. Les états refusés au-delà de leur
capacité restent dépendants de la rediffusion DX et du journal VB rejoué lors
du rattrapage.

Le classement conserve ses limites de taille et ses scans fractionnés ; les
pages appliquent au maximum quatre lignes par callback. Les états identiques
ou remplacés sont regroupés quand leur envoi n'a pas commencé. Les refus
temporaires ne justifient ni une file illimitée ni un envoi en rafale.

## Limites de validation

Validation finale du code local : 62 suites Lua 5.1 et 17 tests Node réussis,
55 fichiers de production compilés en Lua 5.1. Les 62 suites sont inscrites
dans les workflows de validation et de publication. Le test d'alerte GW qui
dépendait des espaces du source vérifie désormais le vrai dispatch du message.

Les scénarios automatisés utilisent les vrais modules Lua avec transports et
horloge simulés. Ils couvrent notamment les relais sans communauté, les ordres
d'arrivée différents, les doublons, les paquets perdus, les interruptions,
le reload, la saturation et les bornes du travail découpé. Ils ne mesurent pas
les FPS du client WoW en situation réelle.

Une ancienne migration déjà exécutée a supprimé ses pools sources. Le code ne
peut pas reconstruire automatiquement leurs valeurs originales à partir d'un
total hybride. Ces profils sont conservés ; le correctif empêche la nouvelle
fabrication d'états hybrides, sans inventer un historique de remplacement.

Enfin, la convergence inter-faction exige qu'au moins une chaîne de relais
joignables transporte les données. Elle ne peut pas reconstituer une information
qui n'existe plus chez aucun pair disponible.

## Incident de saturation observé après les changements

Les relevés en jeu montrent une file de rattrapage de 80 à 98 paquets, un
échange paginé sans ligne reçue et des milliers de refus ou abandons internes,
sans refus Blizzard dans les premières captures. La condition de démarrage
du paginé comptait toute la file ancienne : ses emprunts pouvaient bloquer
le nouveau producteur. Les demandes de cartes attendaient également derrière
les réponses anciennes. Les premiers tests de saturation n'avaient pas couvert
ce mélange de producteurs ; les changements de convergence ont aggravé ce cas.

Le correctif réserve les quatre places paginées ci-dessus et donne un service
prioritaire aux demandes SR:T ciblées sur une route connue. Deux demandes de
ce type au maximum attendent ; une nouvelle demande locale pour la même cible
remplace celle qui n'a pas commencé. Les SR diffusés ne deviennent pas urgents.
Une demande ciblée peut reprendre une place empruntée par un ancien LK/LC/LR,
sans évincer les pages de cartes ou les lignes anciennes protégées.

Le nouveau test part de 98 LK et ajoute des LK et progressions ZS pendant
40 secondes : les quatre échanges v6 arrivent en moins de 20 secondes et une
fin de capture en moins de deux secondes. 77 des 98 LK initiaux arrivent,
21 copies empruntées sont évincées, aucune n'expire. Une variante exécutée
avec 240 secondes de trafic donne les mêmes résultats pour ces 98 lignes.
Le scénario suivant remplit la file de 32 ZA et 68 LK : un SR:T récent arrive
en moins de cinq secondes, les 32 ZA et 16 LK protégés sont livrés. Ce sont
des simulations de transport, pas une mesure du réseau réel à trois ponts.

Les diagnostics distinguent désormais refus d'admission locaux et relayés,
évictions, expirations et abandons de transport. Le compteur global reste
cumulatif depuis le chargement et ne représente pas des kills uniques perdus.
Le diagnostic d'historique ancien précise aussi qu'il ne compte pas le v6.

Le chemin K brut n'a pas été élargi : il ne franchit déjà dans HEAD qu'un
voisin, pour préserver les contrôles d'identité. Les scores de tueurs ennemis
non amis directs dépendent donc des snapshots LK. La congestion peut aussi
refuser un K direct dans la file ordinaire. K transporte un total cumulatif :
un prochain K ou LK admis peut rattraper le score. Ajouter des réessais urgents
à tous les K augmenterait la charge et pourrait rejouer l'activité avec une
date de réception nouvelle ; ce correctif ne fait pas ce changement.

La reprise effective du total Horde et des pages reçues doit encore être
vérifiée en jeu après reload. La livraison de chaque copie ancienne empruntée
sous surcharge continue n'est pas garantie.

### Nouveau relevé : le premier correctif ne suffit pas

Après reload, le joueur constate encore zéro page et zéro ligne après 181
secondes. Sa file contient 13 paquets carte, zéro paquet paginé et 18 anciens ;
les contrôles de place du producteur paginé ne l'ont jamais bloqué. Les 24
places DX/VB sont occupées. Les compteurs indiquent 327 refus locaux, 811 refus
de relais, 319 évictions et quatre expirations, sans refus Blizzard. Ce relevé
invalide l'explication selon laquelle la seule file paginée locale pleine
empêcherait encore la progression. La version chargée par les trois ponts
Horde n'est pas connue.

Deux défauts supplémentaires sont identifiés dans le code :

- Une demande HR initiale ignorée par un destinataire temporairement occupé
  n'était pas réessayée avant le timeout de 270 secondes ; le silence pouvait
  ensuite être interprété comme l'absence du protocole v6.
- Un relais marquait une enveloppe ciblée comme vue avant de savoir s'il
  pouvait la transmettre. Un refus faute de route ou de place condamnait ainsi
  une autre copie du même paquet. Le cas « aucune tâche routable » n'était pas
  comptabilisé parmi les refus.

Ces défauts peuvent produire l'attente observée, mais le relevé local ne prouve
pas lequel a affecté la demande en cours chez ses destinataires. Les délais
et pertes constatés ne doivent pas être présentés comme résolus sur la seule
base des tests locaux.

La reprise HR émet désormais au plus deux demandes supplémentaires, avec le
même nonce, numéro de page et contenu, espacées de 90 secondes actives. Elle
ne prolonge pas la limite initiale de 270 secondes et s'annule dès qu'une
réponse HA/HB valide arrive. Les pauses en combat ne regroupent pas les deux
réessais en une rafale à la sortie du combat. Le test
`audit_v6_silent_first_request.test.lua` échoue avec le code précédent et passe
avec le correctif : première demande perdue, destinataire temporairement
occupé, silence permanent borné, réponse normale, page incomplète et pause.

Pour une enveloppe ciblée à transmettre, le relais ne marque maintenant le
paquet comme vu qu'après admission réussie. Une autre copie valide peut donc
retenter un refus faute de route ou de place. Les broadcasts, K et livraisons
locales gardent leur déduplication antérieure ; aucune recherche par diffusion
ni augmentation du débit n'a été ajoutée. Le test
`forever_beta_relay_seen_recovery.test.lua` reproduit les échecs de route
absente, route en boucle et file pleine, puis vérifie une livraison unique
après reprise. Les refus sans tâche routable apparaissent séparément dans le
diagnostic, localement et en relais ; auparavant ils étaient silencieux.

Ce correctif local des relances peut aussi interroger un destinataire ancien.
Le changement de déduplication, lui, ne protège que les relais qui ont chargé
ce code. Il ne permet pas de promettre une reprise sur des ponts dont la
version chargée reste inconnue. Les copies anciennes évincées sous saturation
restent une limite distincte ; ces deux corrections ne garantissent pas un
compteur de drops nul.

### Reprise observée en v5 et compatibilité des pairs

Un relevé ultérieur, 617 secondes après le début de la manche avec Farah Vt,
montre `Ladder v5: receiving page`, 28 pages, 292 lignes, zéro ligne filtrée,
bucket LK 21/64. Le total Horde passe ensuite de 98 519 à 98 929, puis 100 313,
100 749, 100 751 et 100 782. Une première lecture erronée de la petite capture
avait donné 103 113 ; la relecture du fichier original confirme 100 313. Il n'y
a pas de baisse du total dans cette série.
Le rattrapage importe donc bien des données en jeu. Cela ne démontre ni un
transfert terminé ni la disparition de la surcharge : le relevé à neuf minutes
compte encore 833 refus locaux, 2 213 refus de relais et 758 évictions.

Le code avant adaptation n'accepte que le protocole paginé v5. Son NH et celui
de la version adaptée annonçaient la même version d'addon, sans capacité de
protocole. Un pair ancien pouvait ainsi ignorer les requêtes v6 pendant les
270 secondes précédant le fallback. Le conseil de refaire un reload après
trois minutes pouvait interrompre ce fallback ; il a été retiré. Le succès du
v5 appuie cette piste, sans prouver à lui seul la version chargée par le pair.

La négociation choisit désormais v6 pour les pairs Beta annonçant `~lp6` dans
NH, et v5 immédiatement pour les autres. Une passe v5 reste partielle et laisse
le scheduler demander LC/LR par le fallback v4 borné. Le checkpoint LC/LR d'une
passe v6 interrompue est conservé pendant une passe v5. Les pairs communautaires
hors relais Beta gardent leur sonde v6 suivie du fallback existant.

Le suffixe est produit à la frontière `BetaNetwork:Send` pour les NH contenant
la version locale, ce qui couvre le heartbeat et ScanCommunityMembers. Les
anciens relais acceptent ce payload sans le parser. Le cache est limité à
128 origines et 300 secondes ; seule une annonce NH le rafraîchit, et une
annonce plus ancienne reçue en retard ne remplace pas la capacité récente.
Ce renseignement choisit un protocole, sans apporter d'autorité supplémentaire.

### Comparaison de charge avant/après

Le banc `tests/forever_beta_head_comparison.audit.lua` compare le transport de
HEAD au transport courant avec les mêmes opérations : neuf minutes, 100
origines NH toutes les 45 secondes, trois amis Battle.net opposés, un LK
ciblé par seconde, un lot de 32 ZA et 14 DX par minute. Il utilise une copie
temporaire de HEAD, sans remplacer le code du workspace.

Les deux versions transmettent 234 156 octets NH. Avec des annonces étalées
sur 45 secondes, elles livrent 540/540 LK, 32/32 ZA et 126/126 DX. Avec les
mêmes origines synchronisées en rafales, HEAD livre 540/540 LK et 124/126 DX ;
le transport courant livre 527/540 LK et 126/126 DX, avec 13 évictions LK.
Ses 156 refus locaux ZA sont des réessais : les 32 pages finissent livrées.

Cette simulation isole une régression de livraison LK sous rafales, en échange
d'une meilleure livraison des états. Elle ne montre pas d'augmentation du
volume NH à charge égale. Elle ne reproduit pas les pairs et producteurs
exacts du joueur ; aucun changement d'intervalle NH ou de diffusion n'a été
appliqué sur cette seule base. Les pertes des copies empruntées restent à
résoudre sans retirer les protections des cartes et de la domination.

### Classement ouvert pendant le rattrapage : tentatives de recalcul

Le joueur signale des pics CPU avec le classement ouvert. Un défaut du délai
de reconstruction a été reproduit : les nouvelles métadonnées LK peuvent
interrompre un calcul découpé, mais le délai de trois secondes ne tenait compte
que des calculs terminés. Les tentatives interrompues pouvaient donc reprendre
à chaque demande d'affichage. Ce mécanisme existait déjà dans HEAD ; un afflux
de rattrapage peut le solliciter davantage sans que la capture CPU suffise à
lui attribuer tous les pics.

Le délai est maintenant appliqué à l'entrée du constructeur, en tenant compte
du dernier démarrage et de la dernière fin. Une seule minuterie différée est
conservée, la vue précédente reste affichée et l'initialisation sans vue valide
reste immédiate. Les scores reçus continuent d'être importés.

Le test `audit_lk_import_display_cost.test.lua` utilise le vrai récepteur LK
avec une base de 4 000 joueurs. Il distingue un consommateur agressif demandant
la vue après chaque ligne et une cadence d'une demande par seconde. Il vérifie
la borne des tentatives, la conservation de l'affichage et le total final
après la dernière ligne. Les compteurs de travail simulés ne sont pas une
mesure des FPS en jeu ; une comparaison classement ouvert/fermé reste utile.
Sur 60 LK en six secondes, le consommateur agressif passe de 30 constructions
et 30 scans de métadonnées à deux de chaque. À la cadence simulée d'une demande
par seconde, sur 12 LK, le résultat est plus modeste : six constructions avant,
cinq après. Ce second scénario évite d'assimiler le consommateur agressif à la
cadence réelle de l'interface.

Dans le relevé à 32 minutes, le balayage v5 indique 80 pages et 888 lignes,
et l'échange historique atteint 590 lignes avec l'état « received, sending
back ». La file de rattrapage est vide à cet instant, mais 20 états DX/VB
restent en attente. Les drops cumulés passent de 7 102 à 7 554 : 159 refus
locaux, 123 refus de relais et 170 évictions. Neuf expirations supplémentaires
sont comptées séparément : ce chemin incrémente le détail par type et le
compteur d'expirations, mais pas le total global `dropped`. Le diagnostic
compte des opérations de transport, pas des pertes de lignes uniques.
Le transfert progresse, sans démontrer la
résolution de la congestion ni la fin de tous les échanges.

### Correction des pertes sous rafales et regroupement des répétitions

Une présence NH non commencée peut désormais emprunter une réservation vide.
Les données prioritaires récupèrent cette place si nécessaire, après validation
de leur route. Une NH ne peut plus évincer une ligne déjà admise quand la file
est pleine. La limite globale reste 128 paquets, les plafonds DX/VB et paginés
restent respectivement 24 et quatre, le débit total reste 1 000 octets/s avec
un burst de 500 octets. Les calculs d'admission parcourent au plus la file
bornée ; ils n'ajoutent ni timer ni parcours de population.

Le même scénario synchronisé de neuf minutes passe de 527/540 LK livrés à
540/540, avec 32/32 ZA et 126/126 DX dans les deux cas. Le volume NH reste
234 156 octets et les 100 origines sont découvertes par chacun des trois ponts
Horde simulés. Les évictions passent de 13 à zéro, les refus NH de 16 à quatre.
Le compteur global reste à 160 : 156 tentatives ZA refusées puis réessayées
avec succès, plus les quatre refus NH. Il ne mesure donc pas une proportion
de scores définitivement perdus. La variante aux présences étalées conserve
également toutes les livraisons. Le test de réservation remplit aussi 128
places avec NH puis vérifie la récupération des places LK, HB, DX et la
priorité d'un événement de capture, sans dépasser la borne.

Les SR explicitement territoriaux (`:T`) encore entièrement en attente sont
regroupés par origine et destination, localement et sur les ponts. La dernière
demande remplace la précédente à sa position ; F/S et une émission déjà
commencée restent distincts. Les GH sont regroupés seulement si origine,
destination et payload complet sont identiques. Aucune preuve causale
différente ni aucun auteur ne sont fusionnés. Le regroupement n'impose pas de
nouveau délai aux demandes déjà transmises et ne coupe pas les relais LK
nécessaires aux pairs anciens.

`forever_beta_pending_duplicates.test.lua` échoue avec le code précédent puis
vérifie que 40 répétitions SR/GH utilisent les deux places déjà occupées,
même avec une file ordinaire pleine. Il couvre les auteurs/destinations
différents, les demandes F/S, les preuves distinctes, l'ordre de file et une
arrivée pendant l'émission. Le diagnostic expose les regroupements SR et GH.
Ces corrections réduisent des causes reproduites de surcharge ; elles ne
garantissent pas zéro refus avec une charge réelle supérieure au budget.

### Priorité des forteresses et contrôle des alertes Horde

À la demande du joueur, GH, les fragments G7 de GH et les snapshots GK hors
bataille passent après tout travail prêt de capture, carte, classement,
domination et trafic ordinaire. Ils restent dans la file bornée existante,
avec au plus huit éléments de fond. Une demande ordinaire peut récupérer une
place occupée par une preuve non commencée ; cette récupération valide d'abord
sa route et respecte les plafonds des voies paginées et DX/VB. Les paquets
déjà partiellement envoyés ne sont pas évincés. Les historiques peuvent être
retardés ou refusés davantage sous charge : la réussite se juge désormais
aussi par le type de données livré, pas seulement par le total des drops.

GK en cours de bataille et les résultats GC/GA gardent leur priorité. Un
fragment G7 de GK/GC/GA garde son traitement antérieur, car les fragments
suivants ne donnent pas le statut de la bataille. Aucun événement ne reçoit
une autorité supplémentaire. `forever_beta_fortress_background.test.lua`
vérifie l'ordre réel d'émission, la borne de huit, la livraison au repos,
la récupération de places par SR/LK et les plafonds globaux.

Le joueur observe ensuite seulement des alertes Alliance, tout en précisant
qu'il ignore si un événement Horde a eu lieu pendant cette période. Le test
`forever_enemy_live_alerts.test.lua` fait entrer un C et un GE Horde par le
vrai dispatcher Battle.net, avec une enveloppe portant trois noms de relais.
Les handlers de production appliquent la capture et le commandant, puis
émettent chacun une alerte sur le client Alliance ; les replays n'en émettent
pas d'autre. Ce test ne reconstitue pas les événements du serveur ni la charge
des ponts du joueur. Aucun filtre d'alerte ou garde d'authenticité n'a été
relâché à partir de ce seul signalement.

La v5/v6 concerne le rattrapage du classement, pas le format des alertes C/GE.
Un reload charge les fichiers locaux modifiés même sans commit. Les autres
joueurs gardent leurs fichiers installés ; un commit ne les met pas à jour.
L'absence d'annonce fraîche `lp6` justifie le choix de v5, mais ne donne pas
la révision exacte du pair ni la cause d'une alerte absente. Au dernier relevé,
la passe v5 est interrompue à 61 pages/684 lignes après trois réessais : le
checkpoint conservé ne constitue pas une validation de convergence complète.
