1.0.9

**Overlord Forever 1.0.9**

- Show the top HUD contextually by default near capture objectives, mines, forests and guild keeps. Keep Always and Never options, preserve manual dismissal, and add `/ov hud auto|on|off|toggle` for macros.
- Use Classic race portraits in the leaderboard when available, with Blizzard atlas fallback for other races.
- Suppress automatic welcome, daily report, featured front and siege reminder pop-ups when the Forever beta did not load SavedVariables. The guide remains available on demand, and normal one-time/daily behavior remains when the saved state loads.
- Keep the public addon independent of any personal SavedVariables bridge or account data.

**Overlord Forever 1.0.8**

- Purge the disputed weekly kill row from the live leaderboard, pooled scores and recovery snapshot. A stale snapshot can no longer restore it on reconnect.
- Keep all other scores and the campaign-scoped expiry unchanged. The cleanup remains sliced across frames to avoid login stutter.

**Overlord Forever 1.0.7**

- Credit confirmed honorable victories to DPS and healers alike. Reconcile the PvP counter with killing blows so the same death cannot score twice when events arrive in either order.
- Remove one disputed kill row from the 09/22/2026 campaign and reject stale copies relayed by older clients. The exclusion expires at the next weekly reset; other scores are unchanged.
- Keep the featured-front x2 bonus and existing bounded synchronization. No private SavedVariables or local recovery data is included.


**Overlord Forever 1.0.6**

- When the Forever beta fails to load SavedVariables, begin the existing bounded, direct leaderboard catch-up shortly after the territorial login burst. If the first peer is also empty, rotate through up to three more peers promptly instead of treating an empty response as recovered data.
- Keep the Retail-style community, channel, group and Battle.net synchronization, campaign guards and per-frame work budgets. No player backup or local bridge is packaged in this release.
- The beta client still needs the included Windows SavedVariables repair for reliable persistence when no peer with the old data remains online.

**Overlord Forever 1.0.5**

- Detect a newly joined Overlord community immediately from the Community button, even while the previous negative club lookup is cached.
- Refresh the panel when Blizzard reports a club join or leave, and open the detected Overlord club directly from the button. Nearby events share one refresh to avoid stutter.
- Keep the global leaderboard, parallel sync relays, US Guild Keep schedule and data recovery behavior from 1.0.4.

- Re-enable the Overlord community button with the global Forever invite `0m7kdXcnvR`. The numeric club ID is discovered automatically through `C_Club` after joining.
- Use one global Forever data pool. Existing US, EU, FR, DE and NA leaderboard, domination, keep, outpost, victory-bonus, Commander and Contract records migrate into the global pool without discarding current-campaign data.
- Run Communities and the bounded channel/group/Battle.net relay together. Members and non-members receive the same authoritative payload families, including late-login history catch-up.
- Keep rolling updates compatible with 1.0.3 by accepting legacy US/EU packet and bridge tags while emitting the new global tag.
- Use the US Tuesday weekly campaign boundary for every Forever client, and schedule every Guild Keep on the Retail US window: 6:00–7:00 PM Pacific, with the reminder starting one hour earlier.
- Retain the Classic terrain coordinate repairs, Commander mode, Contracts and SavedVariables recovery bridge introduced in 1.0.3.

**Beta limitation**

- Forever can write addon SavedVariables without loading them on the next session. Run `tools/Repair-ForeverSavedVariables.ps1` from the installed Overlord folder on Windows, then fully restart WoW. The addon never merges an archived campaign into the active week automatically.

**Recommended after updating**

- Fully restart WoW after installing because this release adds modules to the TOC.
- Join the Overlord community from the in-game button for the strongest roster path. The channel, group and Battle.net relay remains active as a fallback.
- Other participants should update to 1.0.5 so the community panel detects membership promptly and all clients keep the same global pool and Guild Keep clock.
