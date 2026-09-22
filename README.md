# Overlord Forever

Addon **World of Warcraft Forever** pour la capture de zones sur les fronts du monde ouvert : synchronisation entre joueurs, carte, classement et domination hebdomadaire.

| | |
|---|---|
| **Auteur** | Troma |
| **Licence** | All Rights Reserved |
| **Version** | 1.0.6 |
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

Sous Windows, le contournement local s'installe depuis le dossier `Overlord` :

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Repair-ForeverSavedVariables.ps1
```

Le script sauvegarde les fichiers existants dans `_local`, puis relie le dossier
de sauvegarde du compte à l'addon et ajoute sa lecture **à la fin du TOC**, avant
`ADDON_LOADED`. Il lit toujours le fichier courant, même quand WoW le remplace à
la déconnexion. Aucun programme ne doit rester ouvert. Il ne modifie pas `WTF`.
Le même principe est documenté par [ForeverSVFix](https://github.com/nobewayo/ForeverSVFix#how-it-works).

**Quitter complètement puis relancer WoW** après installation. Capturer un point,
faire `/reload`, puis connecter un autre personnage du même compte : le point
doit conserver son propriétaire et les annonces déjà vues doivent rester masquées.
La validation en jeu reste nécessaire sur le client Windows.

Si plusieurs comptes ont une sauvegarde, ajouter `-Account "ACCOUNT#1"`.
Le lien est propre à ce compte : le désactiver avant d'utiliser un autre compte
WoW dans cette installation. Relancer le script après une mise à jour qui remplace
le TOC. Quand Blizzard corrige le problème, utiliser le même script avec `-Disable`.
Cette option conserve les sauvegardes. Pour un zip manuel, désactiver le lien
et exclure `_local` ; la publication GitHub/CurseForge enlève ce bloc automatiquement.

### Distinguer un chargement lent, un reset et une perte

Le classement peut se remplir progressivement au login pendant le rattrapage
par les pairs. Un tableau initialement vide ne prouve pas une perte sur disque.
`/ov persistence` affiche si une sauvegarde était présente avant l’initialisation,
le résultat du pont local (après réinstallation du script), les epochs de campagne
au login et après initialisation, ainsi que les totaux actifs et de la dernière archive.
`nil` pour le pont signifie que la sonde locale n’est pas installée ; `false` signifie
que son passage n’a trouvé aucune table de sauvegarde.

Un reset hebdomadaire ouvre normalement un nouveau classement. Une copie complète
de la campagne précédente est maintenant conservée par région dans
`leaderboardPreviousCampaigns`, avec les métadonnées et les rangs hors du top de
l’historique compact. Cette copie ne se réinjecte jamais automatiquement dans une
nouvelle campagne. Le script de réparation conserve les scripts de récupération
locaux déjà installés et sauvegarde leurs fichiers avant de réparer le TOC.

## Fronts de guerre

Overlord Forever gère quatre fronts indépendants, chacun avec ses zones de capture, prérequis et capitales de faction :

- **Hautes-terres d'Arathi** (`arathi`) : points de capture recalés sur la carte Classic / Forever
- **Loch Modan** (`loch_modan`)
- **Durotar** (`durotar`)
- **Orneval / Ashenvale** (`ashenvale`)

Le panneau principal permet de basculer entre les fronts disponibles. Les pins et la logique de capture s'adaptent à la carte où vous vous trouvez.

Pas de Gilnéas, Forêt d'Elwynn, ni Tarides du Sud (cartes Forever, pas de scission Cataclysm).

## Fonctionnalités

### Capture et contrôle de zones

- Points de capture en open world avec timer de maintien, contestation et prérequis entre zones.
- Indicateur HUD de zone active (`/ov where`).
- Section **Zone active** dans le panneau (visible uniquement lorsqu'une capture est en cours).

### Synchronisation multi-joueurs

- État partagé entre joueurs de la même région NA/EU (canal addon, groupe/raid et relais Battle.net). Forever n'a pas de royaumes.
- Pendant la bêta, le mode communauté est grisé. Les captures, fortins, avant-postes, classements et historiques passent par ces passerelles, y compris entre factions via Battle.net.
- Le relais conserve l'auteur initial, élimine les doublons et limite les trajets à trois relais. Son budget partagé est de 1 Ko/s, réserve de 500 octets comprise, avec 128 messages en attente au maximum. Les grosses données sont fragmentées ; trois amis Battle.net au maximum sont sélectionnés par message, à tour de rôle.
- Tous les participants doivent avoir cette version et un chemin de communication entre eux. La découverte périodique permet le rattrapage ; une file saturée ou un paquet expiré peut retarder la synchronisation. Les auteurs antérieurs sont attestés par le relais, pas authentifiés directement par Blizzard. Les contrôles de campagne et de validité des données restent actifs.
- Noms Forever en deux parties (ex. `Troma Orcbane`) acceptés dans la sync et les whispers.
- Commande `/ov sync` pour demander un rattrapage manuel.

Le canal utilisé par cette version Forever est `OverlordF`. Le classement se
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

- **Mines d'or**, renforts et barricades selon le front.
- Économie locale liée à la progression de capture.

### Guild Keep

- Fortins de guilde sur des zones dédiées (Serres-Rocheuses, Les Paluns, Terres Ingrates, La Croisée, Les Carmines, Mulgore).
- Capture intra-guilde, fenêtre horaire de vulnérabilité, sync dédiée (`GK`).

### Autres systèmes

- **Kills JcJ en monde ouvert** comptés partout, à tous les niveaux, même hors des fronts Forever. Les instances (BG, arènes, donjons et raids) sont exclues.
- **Avant-postes** sur les quatre fronts.
- Appel de faction pour alerter les alliés accessibles par les passerelles de synchronisation.
- **Commandant** : rôle du chef de groupe sur un front, position sur la carte/minimap,
  badge de nameplate et libération du rôle à la mort ou à la perte du commandement.
  La communauté n'est pas requise ; les annonces passent aussi par les bridges Forever.
- **Contrats en or** : cibles ennemies connues, preuves de kill, approbation du
  signataire et préparation du règlement par courrier/COD. Les identités utilisent
  le prénom et le nom Forever, sans royaume. L'envoi du courrier reste manuel.
  Voir la [vérification des API et les limites de validation](docs/forever-commandant-contracts.md).

### Langues

Interface traduite en **anglais**, **français**, **espagnol**, **allemand** et **russe** dans `Locales.lua`.

## Commandes

Alias : `/ov` et `/overlord`. Tapez **`/ov help`** en jeu pour la liste complète.

| Commande | Description |
|---|---|
| `/ov` | Ouvre le panneau principal |
| `/ov show` / `hide` / `toggle` | Affiche, cache ou bascule l'interface |
| `/ov status` | État de toutes les zones du front |
| `/ov zones` | Zones disponibles avec coordonnées |
| `/ov where` | Bascule l'indicateur de zone |
| `/ov start <zone>` | Démarre la capture d'une zone |
| `/ov lb` | Classement |
| `/ov sync [Joueur]` | Demande une synchronisation |
| `/ov dom` | Debug barre domination (développement) |
| `/ov scale [0.8–1.2]` | Échelle du panneau |
| `/ov guide` | Guide visuel rapide |

## Options

**Échap → Options → AddOns → Overlord** : échelle UI, opacité des overlays carte/minimap, notifications chat, waypoint automatique, affichage minimap, etc.

## Releases

Les versions publiées sur CurseForge sont déclenchées par des **tags Git** (`X.Y.Z`, sans préfixe `v`) sur `main`. Le fichier `CHANGELOG.md` contient les notes de patch de la version en cours.

## Développement

Ce dépôt inclut des fichiers ignorés par le client WoW (`.github/`, `CHANGELOG.md`, `.pkgmeta`, etc.) : seuls les fichiers listés dans `Overlord.toc` sont chargés en jeu.

Positions de capture et références Classic : [audit des emplacements](docs/forever-capture-locations.md).
