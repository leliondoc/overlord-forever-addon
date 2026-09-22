1.0.3

**Overlord Forever 1.0.3**

- Make the leaderboard converge after login without Communities. Full history catch-up now crosses addon channels, groups and Battle.net bridges, retries saturated queues, and returns the merged result to late clients.
- Forward captures, kills, guild metadata, keeps, outposts, domination, victory bonuses and resource stocks through the same bounded Forever relay. NA and EU remain isolated.
- Restore Commander mode on Forever, including map/minimap position, nameplate badge, group-leader lifecycle and bridge synchronization.
- Restore gold Contracts with Forever two-part identities, kill proofs, signer approval, duplicate guards and manual mail/COD settlement.
- Reposition 22 capture objectives in Arathi, Durotar, Ashenvale and Loch Modan on Classic/Forever terrain. Prefer Vanilla map coordinate frames and keep all objective IDs and saved capture states stable.
- Preserve a complete previous-campaign leaderboard checkpoint per region. Add `/ov persistence` to distinguish peer catch-up, a weekly rollover and the Forever beta SavedVariables loader bug.
- Harden the Windows SavedVariables repair bridge: keep private recovery hooks, follow WoW file rotation and expose whether the live save loaded before initialization.
- Keep outdoor PvP kills at all levels and existing mine/forest Classic map fixes from 1.0.2.

**Beta limitation**

- Forever can write addon SavedVariables without loading them on the next session. Run `tools/Repair-ForeverSavedVariables.ps1` from the installed Overlord folder on Windows, then fully restart WoW. The addon never merges an archived campaign into the active week automatically.

**Recommended after updating**

- Fully restart WoW after installing because this release adds modules to the TOC.
- Other participants need 1.0.3 for complete relay coverage and the fastest leaderboard catch-up. Communities are not required; a connected channel, group or Battle.net path is still needed.
