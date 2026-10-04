# Audit complet Overlord Forever 1.4.1 — 2026-10-04

Audit du dépôt entier (pas seulement depuis le dernier tag), en lecture seule, sans mesure en jeu.
Trois passes Sonnet séquentielles (réseau, performance, qualité) puis vérification manuelle des
affirmations les plus lourdes (marquées « vérifié »). Base : 100 tests verts sous Lua 5.1, tous les
fichiers se chargent, dépôt propre à 3d299b1.

## Verdict global

| Axe | Verdict | En une phrase |
|---|---|---|
| Convergence intra-faction | **Correct avec réserves** | Les scores et la barre convergent par construction ; la carte dépend d'horodatages PC et les captures ennemies arrivent trop rarement pour être validées « rouge ». |
| Trafic / tenue à l'échelle | **Fragile au lancement** | Trois amplificateurs N-vers-N subsistent (réponses classe/guilde, ponts BNet multiples, copie GROUP des paquets canal). |
| Sécurité anti-triche | **Trou majeur** | La « confiance communauté » héritée de Retail est vide : tout pair entendu une fois est de confiance pour TV/VB. |
| FPS / freezes | **Négligeable en solo, perceptible en foule 100+** | Déjà bien tranché à 1 ms ; restent ZA en entier par paquet et l'index méta qui repart sans fin au lancement. |
| RAM / SavedVariables | **À corriger** | 2,98 MB de SavedVariables pour 2 200 joueurs, ladder sérialisé deux fois (vérifié) ; 15-22 MB en RAM. |
| Code mort / restes Retail | **~4 300 lignes (≈ 5,6 %)** | Communautés C_Club, ponts R1/R2/ST, RP group, Gilneas/Barrens, secret values 12.x, migrations régions. |

Le réseau n'est pas « pas mal » par hasard : files bornées, rétropression, catch-up point à point,
état en ensembles d'événements, élection LK. Ce qui manque est ce qui n'a jamais été testé en vrai :
des centaines de joueurs sur un canal et un client modifié.

## 1. Réseau et convergence

### Architecture lue dans le code
- Transport unique `net` (SyncBetaNetwork.lua) : enveloppe `region|id|at|target|path|kind|payload`,
  4 sauts max, TTL 120 s, fragments de 170 caractères. File 128 paquets en 4 voies (urgent, bulk,
  catch-up 16 réservés, VB 24 réservés), budget 1000 B/s.
- Canal `OverlordF` + suffixe de ruleset (RealmPools.lua:19), 0,8 msg/s. K d'origine 1 fois/30 s,
  jamais ZA/LK/LC/LR/LO/LOC sur canal.
- Catch-up strictement entre voisins directs (hops==1), SR ≈ 2 répondants par diffusion
  (Sync.lua:5321), ZA mono-source sans quorum (Sync.lua:7998), tirage d'un voisin toutes les
  150 ± 30 s en alternant ami/ennemi (Sync.lua:2006-2045).
- L'élection de pont n'existe que pour les totaux LK ennemis (SyncBetaNetwork.lua:1777), pas pour
  C/ZS/TV/FR/OP ennemis (vérifié).
- Horodatages de capture = `time()` (horloge PC), paquets = `GetServerTime` ; tolérance 300 s
  (Sync.lua:158).

### Convergence (même faction)
| # | Sév. | Cas | Auto-guérison |
|---|---|---|---|
| C1 | majeur | LWW sur horloge PC : un PC en avance ≤ 300 s fait rejeter une vraie capture ultérieure comme « stale » (Sync.lua:4513-4535). Tout le monde converge vers le même état, mais faux. | Jamais avant nouvelle capture / reset |
| C2 | majeur | Orange sans rouge côté ennemi : `FinalSatisfiesLocalRequirement` exige `lastHold ≥ requis-10` (ZoneCaptureLease.lua:1177-1189) mais les ticks inter-factions n'arrivent que toutes les 15 s par BNet (60 s en gros event). Le C/ZS final est refusé « otherCapturer » (Sync.lua:4555, 6860), bail expiré à 90 s. Explication la plus probable du symptôme observé en 1.4.1. | Minutes à indéfini (pull ZA alterné) |
| C3 | majeur | Ruleset : `GetRuleset` fige « pvp » pour la session si l'API ne répond pas au login (RealmPools.lua:47-68, vérifié, choix assumé « comme avant 1.4.0 »). Mauvais canal et mauvais bucket. | /reload |
| C4 | majeur | Versions mixtes : 1.3.x Normal/RP restent sur `OverlordF`/pool global, aucune barrière de version. | Mise à jour |
| C5 | majeur | Victoire manquée (instance, hors ligne) : TV rejoué 2 h seulement (Sync.lua:9648), VB historique par SR mode T 2 lots/réponse. | Barre : minutes ; écran et trêve perdus après 2 h |
| C6 | mineur | Reset hebdo : client non remis à zéro rejette K/C du nouvel epoch quelques secondes (Sync.lua:3162-3171). | ~30 s |
| C7 | mineur | Bas du classement non garanti identique (pages 5000 LK / 1500 LC, snapshot 500). | Dizaines de minutes à heures |
| C8 | mineur | > 512 joueurs : table `peers` FIFO (pas LRU) ; 1000 joueurs ≈ 3500 NH/SH par 120 s > `seen` 2048. | Bruit seulement |

### Trafic (amplificateurs, à traiter avant le 2026-11-04)
- **T1 majeur, vérifié** : demandes de classe/guilde (CR/GR) diffusées canal+groupe+BNet
  (SyncResolution.lua:192, 485) ; chaque auditeur répond par whisper avec 100 % de probabilité hors
  gros event, 25 % constant en gros event (SyncResolution.lua:228, 521), indépendant de N. À 500
  auditeurs : 125 à 500 whispers vers un client. Fix lent : probabilité ≈ 3/N comme SR, ou élection
  par hash.
- **T2 majeur, vérifié** : un paquet venu de BNet est posté sur le canal par chaque joueur qui a un
  ami ennemi (`skipChannel` vrai seulement si transport CHANNEL, SyncBetaNetwork.lua:1626). La dédup
  de contenu ne couvre que OP/LO/LOC/VB/TV et seulement sous charge (l.803). Fix : généraliser
  l'élection LK par hash + repli retardé annulé à l'écoute.
- **T3 majeur** : chaque auditeur canal retransmet vers GROUP (`skipGroup` seulement si RAID/PARTY,
  l.1622) et 1-3 amis BNet. Raid de 40 = 40 copies RAID par paquet. Fix : transport CHANNEL ⇒
  relayer uniquement vers les ponts ennemis.
- **T4** : NH 120 s / SH 60 s à intervalle fixe, non indexé sur la population.
- Déjà bon : K/GI/SR/GR/CR jamais relayés, NH jamais relayé, refus ≤ 3 retries, 5 ponts + 3 amis max.

### Sécurité / abus
Gardes existantes : K accepté du propriétaire seul (Sync.lua:3548), plafonds 10000/500, quarantaine
anti-rafale (SyncAux.lua:4272), crédit capture = capteur direct + 45 s observés, OC exige un membre
de guilde, listes de refus codées.

- **S1 bloquant avant lancement, vérifié** : `IsStrategicSiteCommunitySender` ⇒ `net:IsPeer(sender)`
  (SyncAux.lua:1795-1797) ; `IsPeer` est vrai pour toute origine ayant émis un paquet en 300 s
  (SyncBetaNetwork.lua:593-597, route enregistrée avant dispatch l.1534-1537). Conséquence :
  `IsDominationChannelSenderVerified` (SyncDomination.lua:12-15) et `IsHistoricalReplaySenderTrusted`
  (SyncVictoryBonus.lua:831-835) acceptent n'importe qui. Un TV forgé (Sync.lua:9729-9734) force la
  carte, l'écran de victoire et la barre, relayé 4 sauts. Fix : TV/VB sans preuve locale seulement
  depuis un voisin hops==0/1 avec limite de débit ; plafond du journal brut.
- **S2 majeur** : LK d'un sujet déjà connu accepté de n'importe qui jusqu'au plafond
  (`AuthorizeLeaderboardSubject` « known », Sync.lua:1282). Les listes de refus (Ender Zero, Asmon
  Gold) prouvent l'exploitation. Fix : borne de delta (30 + 1/s) comme le pont LK.
- **S3 majeur** : C/ZS finaux acceptés depuis une origine relayée ; `FinalSatisfiesLocalRequirement`
  vrai sans bail (ZoneCaptureLease.lua:1178). Un ts à now+299 bloque les vraies captures 5 min.
- S4-S6 mineurs : ZA mono-source, récepteur RG fait `InviteUnit` sans gate `IsRPRealm`
  (Sync.lua:1479-1490), R2 fait répondre notre SR à un nom arbitraire.

## 2. Performance (estimations depuis le code, à confirmer par `/ov perf 60` et `/dump GetAddOnMemoryUsage("Overlord")`)

### Ce qui est déjà bien fait (ne pas toucher)
Tick de front unique phasé 1/3 s (Core.lua:4950-4966) ; OnUpdate tous auto-stoppés (barres,
tooltip, driver carte 0,5 s carte fermée, minimap 60→2 Hz à l'arrêt) ; pas de CLEU ; UNIT_AURA
filtré « player » ; GROUP_ROSTER_UPDATE coalescé ; scans de nameplates cachés 2 s ; auras en lecture
groupée par GUID ; tranchage coopératif 1 ms (Leaderboard.lua:316, 1381, 5579, 5645 ;
LeaderboardSearch.lua:7 ; SyncResolution.lua:640) ; login étagé image par image
(Core.lua:3068-3320) ; lignes de classement virtualisées (LeaderboardUI.lua:1829-1852) ; caches
bornés ; profileur `/ov perf`.

### Findings
1. **Majeur au lancement : index méta qui ne finit jamais.** Chaque nom nouveau appelle
   `MarkMetaDirty` (Leaderboard.lua:626-631, 3440-3470), le rebuild tranché détecte
   `sourcesChanged` et repart (1111-1120, 1190-1196). Au lancement tous les noms sont nouveaux :
   ~1,25 ms/image en permanence, ~1,3 KB alloué par joueur et par passe, jamais publié. Compteur à
   lire : `abortedMeta` dans `GetHotIndexStats()`. Fix : insertion incrémentale (comme
   `PatchDedupMetaClassForPlayer` 588-624) ou rejouer le journal au lieu d'abandonner ; plancher 30 s.
2. **Majeur : ZA entiers retraités, nombre croissant avec N.** Élection fixe 12-25 %
   (SyncAux.lua:842-910) ⇒ ~1 ZA/s reçu à N=500 ; `OnReceiveZoneAll` (Sync.lua:7779-8700) refait
   plusieurs passes, closures, `strsplit` complet : 3-8 ms dans une image. Aucun raccourci « contenu
   identique ». Fix : émetteurs ≈ min(pct, 5/population) + hash du payload assemblé après
   Sync.lua:7898.
3. **Majeur, vérifié : SavedVariables 2,98 MB / 150 k lignes pour ~2 200 joueurs.**
   `OverlordDB.leaderboard` est la même table que `leaderboardsByPool[pool]` (Core.lua:3041,
   Leaderboard.lua:2949-2951) ⇒ sérialisée deux fois (35 537 + 35 570 lignes). Plus
   `leaderboardSnapshot` 25 674, `leaderboardPreviousCampaigns` 26 533 (bucket complet avec
   `playerInfo`), `leaderboardDisplayCache` 19 808. ≈ 68 lignes/joueur ⇒ ~14 MB à 10 000 joueurs :
   freeze au /reload et au logout. Fix : `OverlordDB.leaderboard = nil` au PLAYER_LOGOUT
   (Core.lua:5231, restauré en 3041) ; previous sans `playerInfo` ; display cache non persisté ou 500.
4. **RAM** : 15-22 MB estimés, 45-60 MB à 10 000 joueurs ; 4-5 copies par joueur (playerInfo,
   bucket dedup, snapshot 5000 recopié toutes les ~2 min quand dirty ≈ 4 MB de garbage, semaine
   précédente complète, display cache), mémos de noms 2 × 32 768.
5. Mineur : scan de zone toutes les 2 s sur le point de capture (ZoneControl.lua:1521-1607) :
   1-3 ms, 100-300 KB en 40 contre 40. Fix : tranches de 16 unités ou cache d'aura 6-10 s.
6. Mineur : NAME_PLATE_UNIT_ADDED × 3 handlers ; le handler shard est enregistré même hors front
   et appelle `C_Map.GetBestMapForUnit` non caché (Core.lua:1485-1493, GuildKeep.lua:56-60).
   Fix : cache « déjà noté < 60 s », désenregistrer hors front.
7. Mineur : 2-3 KB de garbage par paquet reçu (copies de payload, table `context`,
   `ChannelCoverKey` concatène tout le payload Sync.lua:2342-2349, `VALID_ZS_STATUSES` recréé par ZS
   Sync.lua:6668) ; `_channelCovered` plafonne à 96 clés puis vide tout (Sync.lua:2335-2368).
8. Mineur : minimap 60 Hz en mouvement avec `Vector2D` alloué par tick (MapMarkers.lua:2340) ;
   `"nameplate"..i` concaténé 40× par scan à 14 endroits.
9. Lua 5.1 : SyncAux.lua ≈ 190 locals de fichier (limite 200), Sync ≈ 173, MapMarkers ≈ 171.
   Fonctions géantes : OnReceiveZoneState 1087 l., OnReceiveZoneAll 910, OnSyncRequest 534.
10. Login : étagé, 2-4 s d'étalement sans freeze ; pics mono-image UI/Settings/MapMarkers
    30-80 ms une fois. Le vrai freeze est le fichier SavedVariables (point 3).

## 3. Code mort, restes Retail, duplication

### Piège de nommage (à connaître avant de supprimer)
`BroadcastToCommunity`, `BroadcastToEnemyFactionCommunity`, `BroadcastGeneralToFactionCommunity`,
`SendLoginCatchupSyncToCommunity`, `ScanCommunityMembers`, `IsStrategicSiteCommunitySender` sont le
chemin VIVANT vers le relais (testé par forever_beta_integration.test.lua:149-164). Seule leur
branche C_Club est morte. Supprimer la branche, garder le tronc, renommer ensuite.

### Tier A — supprimer maintenant (~3 500 lignes)
- Communautés C_Club derrière `CommunityModeEnabled = false` (Core.lua:6) : Sync.lua ~1450-1930
  (branches club), SyncAux.lua caches roster 25-560, file whisper 1840-2430, pont EU 1537-1725,
  `BroadcastZoneSnapshotPagesToCommunity` 3095 ; Core.lua `UnifyEuropeanLeaderboardBuckets`
  3742+ ; UI/Button de jonction (~300 l., `COMMUNITY_JOIN_AVAILABLE` UI.lua:7) ; 17 clés
  COMMUNITY_* × 7 langues. ≈ 2 400 l. nettes. Libère ~40 locals dans SyncAux.
- Ponts R1/R2/ST (`OnReceiveST`, `OnReceiveR1`, `OnReceiveR2Relay`, `BroadcastST`,
  `RelayToEnemyBridge`, `bnet_links`, `bridges`) : ST n'est jamais émis (Sync.lua:10437). ~280 l.
- Feature RG « groupe RP » : `IsRPRealm` renvoie toujours faux (Sync.lua:1422-1424) ; Core.lua
  1514-1520, 4515-4527, 4663-4690, 5329-5346 ; Sync.lua 587-589, 1427-1490, 2905-2910, 10640-10646 ;
  2 clés × 7. ~160 l. Le récepteur `OnReceiveRG` est aussi une petite surface d'abus.
- Gilneas + Southern Barrens (fronts qui n'existent plus) : Fronts.lua 60-83, 115-139 ; migration
  `EnsureGilneasZoneRenamePrepared` Core.lua 2664-2754 ; Zones.lua 561, 573-575 ; ~110 lignes de
  ZONE_NAMES/FRONT_* ; 25 alias cassés Commands.lua:7-102. ~300 l.
- Constantes toujours vraies : `SYNC_USE_REALM_CHANNEL`, `SYNC_USE_BNET_OUTBOUND` (Sync.lua:22-23,
  ~18 gardes), 26 tests `BetaNetworkEnabled ~= false`, `HasCommunityClub()` toujours vrai
  (Button.lua:63-67 ⇒ Button 190, 229, 330-331, 391-392, 465-478 morts), General.lua:1064-1068,
  1172-1176, SyncResolution.lua:82-86, SyncStrategicSites.lua:8-13. ~130 l.
- Handlers de kinds morts : `LD` (aucun `Overlord.LadderDigest`), `HC`, résidus v4 dans les voies
  (`borrowedCatchupIndex`/`includeLocal`, `dropBorrowedLegacyForMapControl`), relais NH mort
  (`NH_RELAY_SLOTS` l.501, `relayedPresence` l.932). ~160 l.
- Fonctions sans appelant : `SafeGetRealmName` Core.lua:490, `UpdateWoodDialogBorder`
  UIShared.lua:176, `GetViewerFactionPalette` UIShared.lua:94, `GetGroupMemberGuild` Sync.lua:5812,
  `SetUserWaypointForGuildKeepSite` MapMarkers.lua:3989, `flushSettingsMapSideEffects`
  SettingsPanel.lua:98, `GetNearbyEnemyCountRaw` UI.lua:3176, `GetFactionKillTotals`
  Leaderboard.lua:4396, `GetDominationVictoryBonusTotals` SyncVictoryBonus.lua:842,
  `RebaseRemoteStableByZoneId` ZoneCaptureLease.lua:559, `RelayPoolMatchesLocal` SyncAux.lua:3315,
  `GetKeepCaptureHalfSizePercent` GuildKeep.lua:65, `IsPlayerOnGuildKeepMap` Popups.lua:975,
  `CommunityMemberInOurGroup` SyncAux.lua:1831, GKA `ResetDefaults`/`_ResetState`. ~230 l.
- Stubs vides + appelants : `SavedVarsPoolFromLocaleTag` (Core.lua:1770, appelé Leaderboard
  1009-1011, 3036-3037, 3366-3370), `InferPoolTagFromRealmName` (RealmPools.lua:91, Leaderboard
  1772-1775). ~45 l.
- Clés de locale jamais lues : CAPTURE_OF_STARTED, SETTINGS_DEFAULTS_BUTTON, SETTINGS_SUBTITLE,
  FACTION_CALL_NO_COMMUNITY, GENERAL_NOT_COMMUNITY (× 7).
- Paramètres `includeCommunity/communityMax/communityDelay/allowCommunityInLargeEvent` de `/ov sync`
  (Commands.lua:902-948), Core.lua:313-323, ZoneCaptureLease.lua:1297-1344, SyncOutpost.lua:730-735.

### Tier B — supprimer après UNE vérification en jeu (~780 lignes)
- `/dump C_Secrets, issecretvalue, C_UnitAuras and C_UnitAuras.GetUnitAuras, C_PlayerInfo and
  C_PlayerInfo.GetGlidingInfo, C_AchievementInfo, C_VignetteInfo, C_QuestSession, C_Scenario,
  C_MountJournal and C_MountJournal.Dismount`. Si nil : retirer la machinerie « secret values 12.x »
  (ZoneControl.lua:49-190, Core.lua:450-540 wrappers Safe*, dont `SafeStringEquals` = `a == b` et
  `pcall(tonumber)`/`pcall(math.floor)` Core.lua:482-484 ; CombatTracker.lua:496-530 ;
  Ressources.lua:405-431 dragonriding/forme de voyage Legion ; Core.lua:4378, 4408-4415 Chromie
  Time/C_QuestSession/C_Scenario). ~400 l.
- Kills : `GetKillingBlows` lit le succès Retail 1487 (CombatTracker.lua:272-278) et ne sert que
  dans les branches « pas de GUID attaquant » et « format legacy » (760-766, 787-798). Vérifier avec
  `/ov debugkill` qu'un PARTY_KILL arrive au format GUID, puis retirer (~45 l.). Le chemin GUID,
  validé en jeu (baseline HK), n'en dépend pas.
- Champs `bountyTimes`/`bountyKills` sans écrivain mais encore portés par buckets, fusion,
  pagination, snapshots (Leaderboard.lua 12-13, 1943-1944, 2391, 2473-2579, 2942-2943, 3088-3094,
  5652-5956 ; Core.lua 1779, 3329, 3764). ~45 l. + 2 phases de snapshot. Tester /reload + import.
- Migrations antérieures au wipe beta : pools us/eu/fr/de/na (Core.lua:3747-3855, 5065,
  SyncVictoryBonus.lua:498, 525), `dominationSyncVersion < 10` (2884-2905), minimapOpacity
  (2934-2950), index legacy « short name » Nom-Royaume (Leaderboard.lua:611-629, 1026-1056,
  3913-3929, 4476-4524), purges one-shot 2866-2877. ~290 l. À purger au reset beta de novembre.
- `GetSortedKills`/`GetSortedGuildKills`/`GetSortedCapturesByFaction` (Leaderboard.lua:6920-7050,
  ~140 l.) : utilisées par 3 tests seulement ; réécrire les tests d'abord.

### Tier C — refactorer plus tard / laisser
- Laisser : OnReceiveZoneState / ZoneAll / OnSyncRequest / OnReceiveCapture (cœur vivant, aucune
  branche club, testés via dispatch), `Core:Initialize` (pipeline), machinerie « evidence » (garde de
  transport, pas des stats), `pcall(next)` du Leaderboard (tranches coroutine), atlas Retail avec
  repli (bannières BfA, Trading Post : favoris UI).
- Dédoublonner (~300 l. de gain net) : normalisation de pool × 8 copies (Core.lua:3356,
  Leaderboard.lua:238, Outpost.lua:33, RealmPools.lua:81 référence, Sync.lua:5790,
  SyncAux.lua:3304, SyncOutpost.lua:164, SyncVictoryBonus.lua:32) ; `NormalizeRemoteTimestamp`
  Sync.lua:154 = SyncOutpost.lua:213 ; « court nom » `match("^(.-)%-") or name` × 34 ;
  `"nameplate"..i` × 14 (`SHARD_NAMEPLATE_UNITS` existe Core.lua:757) ; `InstanceSuspended or
  IsInInstance()` × 73 ; `SafeSetPassThroughButtons` × 3 ; horloge serveur × ~18 ;
  `GetCurrentSavedVarsPool` = `GetCurrentLeaderboardSavedVarsPool` = `GetCurrentPoolForSavedVars`.
- Renommer : `BroadcastToCommunity` → `BroadcastToRelay`, `IsStrategicSiteCommunitySender` →
  `IsRelayTrustedSender`, en-tête de SyncStrategicSites.lua (parle encore du bois).

### Tests
106 fichiers, 14 478 lignes. À retirer/retailler avec le code mort : forever_global_community.test.mjs,
audit_v6_nh_capability.test.lua:79-90, forever_beta_integration.test.lua:15, 76-88, 149-164
(à convertir pour le renommage), forever_guild_totals.test.lua:17-25, forever_persistence.test.lua:305
(IsRPRealm), stubs R1/R2 dans forever_beta_multihop_presence, forever_enemy_live_alerts,
forever_alert_transport_audit, forever_event_multihop_audit.
Zones centrales sans test direct : `OnReceiveCapture` (message C), machine d'états front/instance
(CheckActiveFrontZone, OnEnterFront, OnLeaveFront, SuspendForInstance), `ZoneControl:UpdateHoldTimer`
pour les zones (seulement avant-postes), décodage PARTY_KILL, tout le rendu (UI, MapMarkers, Popups,
LeaderboardUI ≈ 12 000 l.) et Commands/Button/ActionShortcut.

### Smells de correction
- GeneralSync.lua:225-241 : `SenderFactionMatches(strict)` s'appuie sur
  `GetOnlineCommunityMemberFaction` (toujours nil) puis sur la confiance relais ; vérifier que le rejet
  des expéditeurs directs hors groupe est voulu pour les messages General reçus par canal.
- Core.lua:2830 : « Initialisation »/« Initialization » codé en dur hors table de langue ;
  Commands.lua:317-398, 712 en anglais en dur (diagnostics).
- `/ov start <zone>` : aucun alias pour les 41 zones réelles ash_*, durotar_*, elwynn_*,
  hillsbrad_*, redridge_*.
- Parité des 7 langues saine (0 clé en trop ; DOM_DEBUG_COUNTS et GUILD_KILL_HELP manquent avec
  repli correct). Les 4 textures sont référencées. Les 15 options ont toutes lecteur et setter.

## 4. Plan proposé, par ordre

1. **Confiance (S1, S2, S3)** : TV/VB sans preuve locale ⇒ voisin direct + limite de débit ;
   delta LK borné sur sujet connu ; C/ZS finaux refusés d'une origine relayée sans bail. Réduit aussi
   le trafic, aucune nouvelle réponse.
2. **Amplificateurs (T1, T2, T3)** : CR/GR à ≈ 3/N ; élection par hash pour tous les kinds venus de
   BNet ; pas de copie GROUP d'un paquet entendu sur le canal.
3. **SavedVariables (perf 3)** : fin de la double sérialisation, previous sans `playerInfo`, display
   cache non persisté. Gain immédiat sur le /reload de chaque joueur.
4. **Lancement (perf 1, 2 ; C3, C4)** : index méta incrémental ; ZA ≈ 5 émetteurs/population + hash
   de contenu ; ne pas figer « pvp » sans réponse API ; avertissement 1.3.x.
5. **Nettoyage Tier A** (~3 500 l.), en commençant par SyncAux (190/200 locals), puis Tier B après le
   `/dump`, puis dédoublonnage Tier C.
6. **Carte et temps (C1, C2)** : captures horodatées `GetServerTime` ; assouplir `lastHold ≥
   requis-10` pour les observateurs inter-factions (à mesurer d'abord avec les compteurs « enemy
   capture final » de `/ov network`).

Chaque étape : tests Lua 5.1 + contrôle de chargement de tous les `*.lua`, puis l'audit habituel
avant publication.

## 5. Réalisé le 2026-10-04 (main, non publié, version 1.4.2 préparée)

Tout le plan de la section 4 a été appliqué, puis ré-audité par deux agents Sonnet (réseau/sécurité,
performance/qualité) dont les trouvailles ont été corrigées. 101 tests Lua 5.1 verts. Code passé de
76 778 à 72 342 lignes (SyncAux 4319 → 2057, Sync 10838 → ~10000, UI 3821 → 3359).

- Confiance : `IsAuthenticatedDirectSender` ; TV différée jusqu'à la capture de la capitale
  (`DeferTotalVictoryUntilEvidence`, première annonce conservée, horodatage normalisé une fois) ;
  budget VB historique 96/h/expéditeur ; LK non sollicité borné (+30, +1/s) ; captures et victoires
  en heure serveur ; futur borné à la réception ; projection du maintien du bail (C2).
- Relais : copies canal des diffusions reçues par Battle.net retenues 2-15 s (1-4 s pour un
  terminal), annulation via les fragments canal, dégradation en copies Battle.net seules ; copie
  groupe retenue et annulée par une copie de raid ; jamais de coalescence ni d'éviction d'une copie
  en vol ; réponses CR/GR ≈ 3/N ; rejeu GE/GX/GD au-delà de la fenêtre de dédoublonnage.
- SavedVariables : alias du ladder retiré à la déconnexion et rétabli à l'init ; point de reprise
  et cache d'affichage allégés. Index méta publié malgré la dérive (drapeau stale, rafraîchi 30 s
  après). Élection ZA ≈ 5 émetteurs par fenêtre ; snapshot identique ignoré 30 s.
- Nettoyage Tier A complet + renommages (BroadcastToRelay, IsKnownRelayPeer, SendToNamedPeers,
  GetRelayPeers, SendLoginCatchupSync…), options de fan-out et constantes mortes supprimées.
- Reste volontairement (Tier B, après vérification en jeu) : machinerie « secret values » 12.x,
  `GetKillingBlows`, champs bounty, migrations régions/legacy, `GetSorted*` test-only ; C1/S3 côté
  ZA (ts futur relayé par la carte) ; `IsKnownRelayPeer` fait encore confiance aux origines relayées
  pour OP/LO/LOC (acceptable : états routiniers vérifiés par site/pool/campagne).
