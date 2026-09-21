1.0.2

**Overlord Forever**

- Fix missing mine and forest markers on Forever maps, including Southshore: use Classic map IDs for continent projections and shared map aliases for world-map/minimap markers and harvesting detection.

- Count outdoor PvP kills worldwide at every character level, including outside war fronts. Instanced combat remains excluded; duplicate and farming protection remains active.

- First public Forever build: Arathi (same capture points as Retail), Loch Modan, Durotar, and Ashenvale war fronts.
- During the beta, Community mode is greyed out. Its gameplay data uses the addon channel, party/raid and Battle.net bridges, including keeps, outposts, leaderboards and history. Relays preserve the original author, deduplicate deliveries and keep NA/EU separate.
- Beta relay traffic shares a 1 KB/s budget with a 500-byte burst allowance across destinations. Bounded queues, fragmented snapshots and targeted return routes limit traffic; existing gameplay validation remains active. Character identity is `Given Family` only.
- Guild keeps on Stonetalon, Wetlands, Badlands, Crossroads, Redridge, and Mulgore. Outposts on the four Forever fronts.
- Gold mines, wood, weekly domination, featured front rotation, and faction call.
- Removed speculative save-loading delays, capture resurrection from map rendering/saving, and reset bypasses. Native SavedVariables loading and the Retail campaign/sync rules are preserved.
- Removed Retail realm catalogs and dead realm migrations. Regions remain NA/EU; character names use Given Family. Whisper validation accepts accented names.
- Initialize the campaign marker before the first leaderboard score, so a new installation keeps its captures after reload and character changes.
- Windows beta workaround: `tools/Repair-ForeverSavedVariables.ps1` restores the live account save when the Forever client fails to load SavedVariables (captures and popup flags). Fully restart WoW after applying it.
- Direct capture and kill identity match Forever two-part names, including compact forms without a space.
- Hall of Fame lists the gold donors. Export, Contracts, and Command stay greyed out in the panel.

**Unchanged**

- Capture hold, contest, and map pins follow the same rules as Retail Overlord.

**Recommended after updating**

- `/reload` after installing, then reopen the map.
- Other participants need this version for the beta relay. Communities are not required; a connected channel/group/Battle.net path is still needed between players.
