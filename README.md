# Overlord Forever

Addon **World of Warcraft Forever** pour la capture de zones sur les fronts du monde ouvert : synchronisation entre joueurs, carte, classement et domination hebdomadaire.

| | |
|---|---|
| **Auteur** | Troma |
| **Licence** | All Rights Reserved |
| **Version** | 1.1.1 |
| **Jeu** | WoW Forever (`## Interface: 16001`) |
| **CurseForge** | https://www.curseforge.com/wow/addons/overlord-forever |
| **Dépôt** | https://github.com/leliondoc/overlord-forever-addon |
| **Retail** | [Overlord](https://www.curseforge.com/wow/addons/overlord) |

## Installation

**Recommandé :** installer via [CurseForge](https://www.curseforge.com/wow/addons/overlord-forever) (client CurseForge ou WoWUp).

**Manuel :** cloner ou télécharger ce dépôt, placer le dossier `Overlord` dans `World of Warcraft\_classic_beta_\Interface\AddOns\`, puis redémarrer WoW.

### Bêta : captures et réglages perdus à la reconnexion

La bêta Forever peut écrire `OverlordDB` dans `WTF`, sans le relire au prochain
`/reload`, changement de personnage ou redémarrage. Les captures et les drapeaux
des pop-up sont alors remplacés par un état neuf. Attendre après la connexion
ne répare pas cette lecture. Voir le [repro sur le forum Blizzard](https://eu.forums.blizzard.com/en/wow/t/addon-savedvariables-never-load-on-160169893/629799).

La synchronisation communautaire récupère automatiquement les classements auprès
des joueurs encore connectés, y compris après un chargement vide. Depuis 1.0.6,
elle essaie rapidement plusieurs pairs si le premier est également vide. Cela
ne remplace pas une sauvegarde persistante : si tous les joueurs perdent leur
état au redémarrage, aucun message d'addon ne peut reconstruire seul les scores.
La version CurseForge ne contient aucune sauvegarde personnelle.

Quand aucune sauvegarde n'a été chargée au login, Overlord ne relance pas
automatiquement les annonces de bienvenue, le rapport quotidien ni le rappel
de siège : il ne peut pas savoir si elles ont déjà été vues. Le guide reste
accessible par `/ov guide` ou le panneau. Ce comportement est inclus pour tous
les joueurs et ne nécessite aucun pont local.

La position déplacée du panneau principal utilise aussi le cache de placement
natif de WoW, par personnage. Le cadre est créé avant la connexion pour récupérer
ce placement lorsque les SavedVariables de l'addon sont absentes. Les positions
sauvegardées dans `OverlordDB` restent prioritaires lorsqu'elles sont présentes.
`/ov resetpos` réinitialise les deux mémorisations du panneau.

### Distinguer un chargement lent, un reset et une perte

Le classement peut se remplir progressivement au login pendant le rattrapage
par les pairs. Un tableau initialement vide ne prouve pas une perte sur disque.
`/ov persistence` affiche si une sauvegarde était présente avant l’initialisation,
les epochs de campagne au login et après initialisation, ainsi que les totaux
actifs et de la dernière archive.

Un reset hebdomadaire ouvre normalement un nouveau classement. La semaine terminée
n’est gardée dans le jeu que par l’historique compact (top 100) ; depuis 1.8.0 aucune
copie complète n’est plus conservée (elle occupait toute la mémoire d’un classement
pendant sept jours), l’historique complet étant archivé hors du jeu.

## Fronts de guerre

Overlord Forever gère sept fronts indépendants avec leurs zones de capture, prérequis et capitales de faction :

- **Hautes-terres d'Arathi** (`arathi`) : points de capture recalés sur la carte Classic / Forever
- **Loch Modan** (`loch_modan`)
- **Durotar** (`durotar`)
- **Orneval / Ashenvale** (`ashenvale`)
- **Forêt d'Elwynn** (`elwynn`), parcours rétabli du front Retail
- **Carmines / Comté-du-Lac** (`redridge`), parcours autour du lac Placide
- **Contreforts de Hautebrande** (`hillsbrad`), front spécial à deux grands cercles : Austrivage (51,2 / 58) et Moulin-de-Tarren (61,8 / 19)

Le panneau principal permet de basculer entre les fronts disponibles. Les pins et la logique de capture s'adaptent à la carte où vous vous trouvez.


## Fonctionnalités

### Capture et contrôle de zones

- Points de capture en open world avec timer de maintien, contestation et prérequis entre zones.
- Indicateur HUD de zone active (`/ov where`).
- Section **Zone active** dans le panneau (visible uniquement lorsqu'une capture est en cours).

### Synchronisation multi-joueurs

- État partagé entre joueurs de la même région NA/EU (canal addon, groupe/raid et relais Battle.net).
- Les communautés ne sont pas utilisées. Les captures, fortins, avant-postes, classements et historiques passent par ces passerelles, y compris entre factions via Battle.net.
- Le relais conserve l'auteur initial, élimine les doublons et limite les trajets à trois relais. Son budget partagé est de 1 Ko/s, réserve de 500 octets comprise, avec 128 messages en attente au maximum. Les grosses données sont fragmentées.
- Ponts Battle.net : jusqu'à 40 amis sont pris en compte. Les amis de l'autre faction entendus récemment sous Overlord servent de ponts (cinq au plus par message), les autres reçoivent des copies à tour de rôle et la présence de chacun permet de se retrouver en deux minutes. Quand une faction compte de nombreux ponts, seule une petite partie d'entre eux fait traverser le trafic de routine ; l'auteur d'un message et les événements terminaux (captures, victoires) traversent toujours.
- Tous les participants doivent avoir cette version et un chemin de communication entre eux. La découverte périodique permet le rattrapage ; une file saturée ou un paquet expiré peut retarder la synchronisation. Les auteurs antérieurs sont attestés par le relais, pas authentifiés directement par Blizzard. Les contrôles de campagne et de validité des données restent actifs.
- Noms Forever en deux parties (ex. `Troma Orcbane`) acceptés dans la sync et les whispers.
- Commande `/ov sync` pour demander un rattrapage manuel.

Le canal utilisé par cette version Forever est `OverlordF` sur le ruleset PvP, `OverlordFE` (Normal), `OverlordFRP` (RP) et `OverlordFHC` (Hardcore) ailleurs. Le classement se
réconcilie aussi à la connexion par échanges ciblés entre pairs : kills,
captures, races et métadonnées de guilde, puis retour des données fusionnées.
Ces échanges passent par les mêmes bridges que les événements en direct, sans
communauté. Les gros rattrapages réessaient les lignes refusées par une file
pleine et disposent d'un délai adapté au débit du relais. Les kills en gros
événement et les messages supplémentaires des envois communautaires (autres
fronts, bonus, stocks) empruntent également ce réseau.

### Carte et minimap

- Overlays sur la carte du monde et la minimap (opacité réglable dans les options).
- Chemin vers l'objectif suivant (optionnel).
- Marqueurs pour zones, fortins, avant-postes et événements liés.

### Panneau principal

- **Activité récente** des fronts sur les cinq dernières minutes.
- Liste des **zones de contrôle** dans le volet latéral (grille deux colonnes, tooltips, icônes carte).
- Barre de **domination hebdomadaire** par front (secondes de contrôle, bonus victoire/bois).
- Compteur de forces alliées / ennemies sur le front.
- Classement des contributeurs (captures, éliminations).

### Ressources et stratégie

- **Mines de coins**, renforts et barricades selon le front.
- Économie locale liée à la progression de capture.

### Guild Keep

- Cinq fortins de guilde, à l'écart des villages de quêtes : Retraite de Roche-Soleil (Serres-Rocheuses), Donjon de Menethil (Les Paluns), Forteresse d'Angor (Terres Ingrates), Bastion de la Savane (Les Tarides) et Fort des Prairies (Mulgore).
- Ouverts à toute heure : un membre de la guilde tient le carré 10 minutes ; seule la faction adverse peut le contester ou le prendre. Le fortin reste à sa guilde jusqu'à une prise ennemie ou le reset hebdomadaire.

### Autres systèmes

- **Victoires honorables Blizzard (VH)** en monde ouvert, à tous les niveaux : une hausse du compteur officiel donne exactement autant de crédits. Les coups fatals et les cibles supposées à la mort ne donnent aucun crédit supplémentaire. Le front du jour ajoute seulement de l’or. Les instances (BG, arènes, donjons et raids) sont exclues.
- Le classement affiche jusqu’à **5 000 joueurs connus**. Les clients à jour échangent jusqu’à 5 000 joueurs par pages reprenables ; les anciens échanges restent limités à 500. Le tri, la préparation du transfert et les envois sont répartis dans le temps ; seules les lignes visibles sont dessinées.
- Les totaux reçus par synchronisation sont acceptés jusqu’à **5 000 VH par joueur et par campagne**, incluses. Au-delà, le total reçu est refusé. Les clients antérieurs à 1.0.13 refusent encore les totaux supérieurs à 1 000 ; tous les participants doivent mettre à jour pour partager ces scores. Le compteur local de VH continue de progresser indépendamment de ce seuil réseau.
- Une fois affiché, le dernier tableau est conservé en mémoire et dans `OverlordDB`. À la prochaine connexion, ce cache borné apparaît immédiatement avec la mention « Classement en mémoire · actualisation… », pendant la préparation des données locales. Il ne déclenche aucun transfert et ne remplace jamais les scores ; les mises à jour réseau continuent en arrière-plan. Une autre campagne, un autre pool ou un format incompatible invalide ce cache. Il ne peut pas survivre au défaut de chargement de toutes les SavedVariables décrit plus haut.
- Le réseau de relais bêta partage un budget estimé de 1 000 octets/s et une file de 128 messages. Le rattrapage adressé dispose de 16 places protégées et d’une part de service de 300 octets/s, afin de progresser même avec du trafic courant. Les envois inutilisés laissent leur débit disponible aux autres messages. Les pages restent vérifiées et soumises aux filtres de scores existants ; `/ov network` affiche leur progression et les copies de présence évitées.
- Les totaux de guilde additionnent les VH de tous les membres connus, même hors du classement affiché, avec dédoublonnage des identités. Ce ne sont pas des victimes uniques. Une guilde temporairement indisponible au chargement ne supprime plus le rattachement connu.
- Le volet latéral **Prochain objectif** remplace le bandeau flottant : vignette du front actuel et nom du prochain point à capturer. Le repère automatique sur la carte et les minuteurs de capture restent disponibles.
- Pendant la bêta, tous les comptes utilisent la même semaine américaine (mardi 08:00 UTC, ancre commune de l’addon). Aucun reset EU le mercredi. Une sauvegarde absente au login ne déclenche plus de faux reset hebdomadaire.
- **Avant-postes** sur les six fronts classiques, plus **Savix Chapel** dans la forêt des Pins-Argentés (61,8 / 64,4), **Aeythyr Lodge** aux Maleterres de l'Est (52,1 / 18,4) et **Lesi's Bear Cave** à Sombrivage (43,4 / 45,8), capturables en permanence. Le front spécial des Contreforts de Hautebrande comporte uniquement ses deux points de capture.
- **Forêts de bois** dans les Paluns (53,8 / 43,7) et en Orneval (33,6 / 63,6).
- Appel de faction pour alerter les alliés accessibles par les passerelles de synchronisation.
- **Commandant** : rôle du chef de groupe sur un front, position sur la carte/minimap,
  badge de nameplate et libération du rôle à la mort ou à la perte du commandement.
  La communauté n'est pas requise ; les annonces passent aussi par les bridges Forever.
- **Contrats en or** : cibles ennemies connues, preuves de kill, approbation du
  signataire et préparation du règlement par courrier/COD. Les identités utilisent
  le prénom et le nom Forever, sans royaume. L'envoi du courrier reste manuel.
  Voir la [vérification des API et les limites de validation](docs/forever-commandant-contracts.md).

### Langues

Interface traduite en **anglais**, **français**, **espagnol**, **allemand**, **russe**, **portugais brésilien** et **chinois simplifié**. Le guide Forever dans `GuideLocales.lua` décrit les sept fronts, les layers et la synchronisation ; les chaînes ptBR et zhCN se trouvent dans leurs fichiers `Locales_*.lua`.

## Commandes

Alias : `/ov` et `/overlord`. Tapez **`/ov help`** en jeu pour la liste complète.

| Commande | Description |
|---|---|
| `/ov` | Liste les commandes |
| `/ov show` / `hide` / `toggle` | Affiche, cache ou bascule l'interface |
| `/ov map` / `map full` / `map compact` / `map off` | Affichage de la carte du monde : complet, compact (noms au survol) ou masqué ; sans argument, passe au mode suivant (aussi le bouton Overlord dans le coin de la carte) |
| `/ov hud on` / `off` / `toggle` | Panneau des coins flottant (même case que les options). Utilisable dans une macro. |
| `/ov status` | État de toutes les zones du front |
| `/ov zones` | Zones disponibles avec coordonnées |
| `/ov where` | Bascule l'indicateur de zone |
| `/ov start <zone>` | Démarre la capture d'une zone |
| `/ov lb` | Classement |
| `/ov sync [Joueur]` | Demande une synchronisation |
| `/ov scale [0.8–1.2]` | Échelle du panneau |
| `/ov guide` | Guide visuel rapide |

## Options

**Échap → Options → AddOns → Overlord** : échelle UI, opacité des overlays carte/minimap, notifications chat, waypoint automatique, affichage minimap, etc.

Carte du monde : trois modes (complet, compact avec les noms au survol, masqué), dans les options, le menu Filtres de la carte, le menu de suivi de la minicarte, le bouton Overlord dans le coin de la carte et `/ov map`.

Le **panneau des coins flottant** est désactivé par défaut (tout son contenu est dans le panneau Overlord). Activé, il apparaît près d'une capture, d'une mine ou d'un fortin et reste visible 15 secondes après la sortie du lieu ; sa croix le désactive (options ou `/ov hud on` pour le rallumer). Le guide est accessible par le bouton Tutoriel du panneau et avec `/ov guide`.

## Releases

Les versions publiées sur CurseForge sont déclenchées par des **tags Git** (`X.Y.Z`, sans préfixe `v`) sur `main`. Le fichier `CHANGELOG.md` contient les notes de patch de la version en cours.

## Développement

Ce dépôt inclut des fichiers ignorés par le client WoW (`.github/`, `CHANGELOG.md`, `.pkgmeta`, etc.) : seuls les fichiers listés dans `Overlord.toc` sont chargés en jeu.

Positions de capture et références Classic : [audit des emplacements](docs/forever-capture-locations.md).

### Transition du compteur PvP

Les scores déjà enregistrés sont conservés : les anciennes versions mélangeaient VH, coups fatals, bonus et certaines attributions supposées. Ils ne peuvent pas être recalculés exactement en VH faute de journal détaillé. Les nouveaux crédits suivent la règle 1 VH = 1 crédit ; tous les participants doivent mettre à jour pour appliquer la même règle. Le prochain reset US ouvrira une campagne entièrement comptée selon cette règle chez les clients à jour.

La bêta peut toujours omettre de charger les SavedVariables. Le correctif empêche un effacement supplémentaire au login mais ne permet pas à Lua de relire un fichier que le client n’a pas chargé. Le rattrapage réseau reste nécessaire dans ce cas.

Les guildes et factions déjà connues ne sont plus remplacées par les copies du classement envoyées par des tiers. Les changements de guilde et les départs doivent venir du personnage concerné ; ses déclarations corrigent les anciennes informations relayées, même si celles-ci portent une date plus récente. Un relais peut toujours renseigner une guilde inconnue. Une affiliation déjà erronée doit être corrigée par le personnage ou par une restauration locale vérifiée.

La monnaie fictive des mines s’appelle **coin** dans l’interface (pluriel **coins**), y compris pour le bonus du front du jour. Les contrats et dons en véritable or du jeu conservent leur libellé.
