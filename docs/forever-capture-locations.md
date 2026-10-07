# Emplacements des captures Forever

Les coordonnées sont celles de Vanilla. Référence reproductible :
[Questie v10.0.0, classicNpcDB.lua](https://github.com/Questie/Questie/blob/v10.0.0/Database/Classic/classicNpcDB.lua).
Les positions de PNJ terrestres ci-dessous servent de points atteignables dans chaque cercle.
Les tests exécutent la détection réelle de capture à ces positions pour les deux familles d’identifiants de cartes.
Cela ne simule pas le relief ni les modifications propres au serveur Forever : un parcours en jeu reste nécessaire pour certifier tous les accès.

## Corrections

- Arathi : fort, crique, fermes, Refuge et Trépas replacés sur leurs positions Vanilla. Les trois noms propres aux objectifs Retail sont remplacés par des repères Classic.
- Durotar : flotte remplacée par la combe des Kolkar, rocher des Esprits par la vallée des Épreuves pour éviter le chemin étroit, capitale nord aux abords d’Orgrimmar.
- Orneval : retraite de Raynewood, Course de la nuit et camp Dent-Rouge recalés ; objectifs de lacs sur des positions de PNJ terrestres.
- Loch Modan : véritable sortie du col sud, vallée des Rois, sommet du barrage et rive est du Loch (au lieu du lac).
- Les cartes Vanilla sont préférées lorsque le client expose aussi les alias Retail.

Les identifiants, prérequis, rayons et scores ne changent pas. Les sauvegardes restaurent les états des objectifs, pas leurs coordonnées. Tous les joueurs doivent charger la même mise à jour ; un ancien client conserve ses anciens cercles jusqu’à mise à jour et rechargement.

## Références des 40 objectifs initiaux

| Objectif (ID historique) | Centre corrigé ou conservé (%) | Référence terrestre Classic : PNJ, position (%) |
| --- | --- | --- |
| `stromgarde` | 25.38, 58.36 | Stromgarde Defender (2584), 25.38 / 58.36 |
| `faldir` | 32.28, 81.38 | Shakes O'Breen (2610), 32.28 / 81.38 |
| `witherbark` | 62.00, 74.00 | Witherbark Headhunter (2556), 62.55 / 73.17 |
| `goshek` | 61.88, 57.33 | Hammerfall Peon (2618), 61.88 / 57.33 |
| `dabyrie` | 54.18, 38.09 | Marcel Dabyrie (4481), 54.18 / 38.09 |
| `refuge` | 45.83, 47.56 | Captain Nials (2700), 45.83 / 47.56 |
| `highperch` | 44.0, 79.4 | Viaduc de Thandol, extrémité nord (1.7.1, relevé en jeu) |
| `newstead` | 21.2, 34.0 | Mur de Thoradin (1.7.1, relevé en jeu) |
| `hammerfell` | 74.18, 33.96 | Uttnar (4954), 74.18 / 33.96 |
| `argorok` | 27.43, 31.39 | Burning Exile (2760), 27.43 / 31.39 |
| `loch_alliance_capital` | 35.40, 46.60 | Mountaineer Ozmok (2510), 35.10 / 46.79 |
| `loch_valley_of_kings` | 22.07, 73.13 | Mountaineer Cobbleflint (1089), 22.07 / 73.13 |
| `loch_south_gate_pass` | 18.18, 84.01 | Mountaineer Pebblebitty (3836), 18.18 / 84.01 |
| `loch_farstrider_lodge` | 82.60, 64.20 | Kat Sampson (954), 82.65 / 64.11 |
| `loch_ironband` | 69.20, 63.80 | Stonesplinter Geomancer (1165), 69.11 / 63.29 |
| `loch_silver_stream_mine` | 34.60, 21.20 | Tunnel Rat Geomancer (1174), 35.41 / 21.57 |
| `loch_algaz_post` | 24.50, 17.30 | Mountaineer Yuttha (1335), 24.74 / 17.71 |
| `loch_stonewrought_dam` | 46.05, 13.61 | Chief Engineer Hinderweir VII (1093), 46.05 / 13.61 |
| `loch_the_loch` | 63.56, 47.92 | Bingles Blastenheimer (6577), 63.56 / 47.92 |
| `loch_horde_capital` | 69.80, 24.10 | Mo'grosh Enforcer (1179), 68.93 / 24.54 |
| `durotar_tiragarde_keep` | 58.40, 57.20 | Kul Tiras Sailor (3128), 58.51 / 57.50 |
| `durotar_alliance_fleet` | 52.08, 82.03 | Kolkar Drudge (3119), 52.08 / 82.03 |
| `durotar_senjin_village` | 54.80, 74.10 | Sen'jin Watcher (3297), 55.21 / 74.78 |
| `durotar_razor_hill` | 52.60, 42.50 | Razor Hill Grunt (5953), 53.06 / 42.48 |
| `durotar_deadeye_shore` | 59.40, 24.30 | Elder Mottled Boar (3100), 59.05 / 24.24 |
| `durotar_southfury` | 39.90, 36.60 | Dire Mottled Boar (3099), 39.40 / 36.54 |
| `durotar_spirit_rock` | 44.63, 68.65 | Foreman Thazz'ril (11378), 44.63 / 68.65 |
| `durotar_thunder_ridge` | 39.20, 25.40 | Lightning Hide (3131), 38.88 / 25.27 |
| `durotar_drygulch_ravine` | 49.10, 29.10 | Dustwind Harpy (3115), 49.96 / 27.56 |
| `durotar_dranosh_blockade` | 46.10, 13.77 | Javnir Nashak (15012), 46.10 / 13.77 |
| `ash_astranaar` | 35.00, 49.00 | Shindrell Swiftfire (3845), 34.67 / 48.84 |
| `ash_maestra` | 26.00, 38.50 | Poste de Maestra (1.7.1, carte Classic) |
| `ash_zoram_strand` | 16.00, 23.50 | Milieu du rivage de Zoram, sur la terre (1.7.1) |
| `ash_darkshore_road` | 27.00, 22.00 | Route du nord vers Sombrivage (1.7.1) |
| `ash_aessina` | 22.00, 52.70 | Sanctuaire d'Aessina, sud-ouest (1.7.1) |
| `ash_stardust` | 32.90, 67.20 | Île des ruines de Poussière-d'étoile, au sud d'Astranaar (1.7.1) |
| `ash_iris_lake` | 45.82, 43.25 | Shadethicket Moss Eater (3780), 45.82 / 43.25 |
| `ash_raynewood` | 60.96, 51.84 | Laughing Sister (4054), 60.96 / 51.84 |
| `ash_dor_danil` | 72.00, 74.00 | Ashenvale Outrunner (12856), 71.91 / 73.67 |
| `ash_splintertree` | 73.50, 61.00 | Qeeju (15131), 73.38 / 61.02 |


1.7.1 : Orneval est redessiné sur 10 objectifs (tracé ouest/sud-ouest ; Night Run, Bloodtooth, Silverwind, Mystral et le lac du Ciel-Déchu retirés) ; le test couvre toujours 59 objectifs.

## Extension 1.0.14 : 57 objectifs

Le test couvre désormais les 57 objectifs et les cartes Classic 1429 (Elwynn) et 1433 (Carmines), ainsi que leurs alias.

- (Avant 1.7.1) Night Run et Mystral avaient leurs propres références ; ces deux objectifs ont été retirés d'Orneval en 1.7.1.
- Les dix références d'Elwynn reprennent la disposition Retail restaurée à la demande de l'auteur. Elles vérifient la détection et le choix de carte ; elles ne constituent pas un relevé indépendant du relief Forever.
- Les sept références des Carmines utilisent les repères de la [carte antérieure à Cataclysm](https://www.mmo4ever.com/wow/map.php?creature=3085&id=44) : Lakeshire 25/43, Alther 53/42, Ilgalar 80/49, Three Corners 18/69, Lakeridge Highway 38/73, Stonewatch Falls 75/67 et Render's Valley 73/78.

La validation automatisée confirme que chaque référence sélectionne le bon objectif dans les deux familles d'identifiants. Elle ne certifie pas la navigation en jeu.

## Extension locale : Austrivage / Moulin-de-Tarren

Le front spécial des Contreforts de Hautebrande utilise la carte Classic 1424 (alias 25), avec seulement deux capitales : Austrivage à 51.2/58.0 et Moulin-de-Tarren à 61.8/19.0. Leur rayon effectif de capture est de 9 unités sur la carte, soit plus du triple du rayon habituel de 2.4. Les cercles restent séparés par la campagne centrale.

Références des deux villes : [aubergiste d'Austrivage à 51/58](https://wowwiki-archive.fandom.com/wiki/Innkeeper_Anderson) et [Tarren Mill vers 60/19](https://classictinker.com/locations/tarren-mill/). Le test couvre les centres, les abords et la séparation des deux cercles. La carte 623 du champ de bataille homonyme est exclue du front de monde ouvert.
