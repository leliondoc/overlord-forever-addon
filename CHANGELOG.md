1.0.0

**Overlord Forever**

- Count outdoor PvP kills worldwide at every character level, including outside war fronts. Instanced combat remains excluded; duplicate and farming protection remains active.

- First public Forever build: Arathi (same capture points as Retail), Loch Modan, Durotar, and Ashenvale war fronts.
- Sync over party/raid, Overlord Forever character communities, and Battle.net friends (cross-faction). Character identity is `Given Family` only: no realm suffix is stored or compared.
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

- `/reload` after installing.
- Join the Overlord Forever community for your region when the invite is published.
