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

## Références des 40 objectifs

| Objectif (ID historique) | Centre corrigé ou conservé (%) | Référence terrestre Classic : PNJ, position (%) |
| --- | --- | --- |
| `stromgarde` | 25.38, 58.36 | Stromgarde Defender (2584), 25.38 / 58.36 |
| `faldir` | 32.28, 81.38 | Shakes O'Breen (2610), 32.28 / 81.38 |
| `witherbark` | 62.00, 74.00 | Witherbark Headhunter (2556), 62.55 / 73.17 |
| `goshek` | 61.88, 57.33 | Hammerfall Peon (2618), 61.88 / 57.33 |
| `dabyrie` | 54.18, 38.09 | Marcel Dabyrie (4481), 54.18 / 38.09 |
| `refuge` | 45.83, 47.56 | Captain Nials (2700), 45.83 / 47.56 |
| `highperch` | 25.19, 40.13 | Highland Strider (2559), 25.19 / 40.13 |
| `newstead` | 18.04, 47.22 | Highland Thrasher (2560), 18.04 / 47.22 |
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
| `ash_iris_lake` | 45.82, 43.25 | Shadethicket Moss Eater (3780), 45.82 / 43.25 |
| `ash_raynewood` | 60.96, 51.84 | Laughing Sister (4054), 60.96 / 51.84 |
| `ash_night_run` | 66.32, 52.56 | Felmusk Satyr (3758), 66.32 / 52.56 |
| `ash_bloodtooth_camp` | 54.75, 79.62 | Ran Bloodtooth (3696), 54.75 / 79.62 |
| `ash_silverwind` | 50.50, 66.00 | Astranaar Sentinel (6087), 50.27 / 66.04 |
| `ash_mystral_lake` | 50.84, 75.08 | Krolg (3897), 50.84 / 75.08 |
| `ash_fallen_sky_lake` | 65.88, 80.30 | Shadethicket Bark Ripper (3784), 65.88 / 80.30 |
| `ash_dor_danil` | 72.00, 74.00 | Ashenvale Outrunner (12856), 71.91 / 73.67 |
| `ash_splintertree` | 73.50, 61.00 | Qeeju (15131), 73.38 / 61.02 |
