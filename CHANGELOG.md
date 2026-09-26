1.0.26

**Overlord Forever 1.0.26**

- Players logging in could keep seeing zones captured by the other faction before their login as neutral. Their map request went through the relay to every Overlord player, and almost all of them (95%) answered with a full snapshot of every zone. For a player of the other faction, all those answers crossed the same Battle.net bridge, filled its queue, and no snapshot arrived complete. A relayed request is now answered by about three players on average; requests addressed to a specific player are still always answered.
- Login state recovery without Communities, like the Retail community catch-up: about twelve seconds after login, Overlord asks three players it has heard on the relay (two of them from the other faction when known) for the zone state only, with a guaranteed answer. It retries twice if nobody is known yet.

**Overlord Forever 1.0.25**

- Guild keep calculations now run at the lowest priority. Sieges happen every six hours and few players take part, so their siege-win bookkeeping should never be felt: it pauses during combat and large events, does one step every tenth of a second in the background instead of as much as possible per frame, and groups keep proofs received from other players for ten seconds before processing them. Results are unchanged; they may simply appear a little later.

**Overlord Forever 1.0.24**

- Smoother frame rate with Overlord windows open during fights. The main panel no longer redraws inside the handling of each network message or kill; it redraws on a following frame, still at most four times per second. The open leaderboard no longer rebuilds its whole ranking continuously while kills arrive: it keeps the current view and refreshes at most every three seconds. The open world map no longer recomputes its whole layout (paths and all their dots) when a zone changes owner; it only recolors what changed.
- Fix a freeze of about a third of a second that came back regularly late in the week, even when moving around without capturing (found with `/ov perf`). The guild keep siege-win check re-examined every closed siege slot of the week for every keep in a single frame; it now spreads that work over a few frames, one keep at a time, with the same result. Between sieges (every six hours) this full check now runs when a siege opens or closes, when a keep really changes, and otherwise every ten minutes as a safety net, instead of every thirty seconds. The siege-slot calculation it repeats about 1,700 times per second during that check is now cached per timestamp and realm time offset, with identical results. Receiving a guild keep daily proof from another player no longer re-examines every later siege slot of that keep inside the network message (about 19 ms each, stacking when several arrive together); the work is grouped per keep and done over the following frames, in the same order.
- Add `/ov perf [seconds]` (default 60): an opt-in profiler that times Overlord's functions for that window, prints any single call over 50 ms in chat as it happens, then lists the slowest and most expensive functions. Work spread over several frames is labelled as such and left out of the rankings. It removes itself at the end and costs nothing when not used.
- Show Lesi Bear Cave on the Kalimdor continent map, like the other Kalimdor outposts.

**Overlord Forever 1.0.23**

- Fix CPU spikes in large events (up to 74% of a frame reported). Every player who received a guild keep or outpost update through the beta relay re-sent it to their raid and channel, and outpost captures and domination boosts were re-published into the relay under each receiver's name. With many Overlord players in one place this multiplied every update by the number of players. Keeps and outposts are now re-sent only when the update was addressed to that player, and those re-publications are skipped when no Community exists; the relay already carries the original.
- Guild kill ranking: the honorable-kill column is wider so totals above 10,000 are no longer cut off ("107..."); totals of a million or more show as "1.2M".
- Make each relayed packet much cheaper: duplicate copies are rejected before any decoding, a packet is decoded once instead of twice, packet history no longer shifts up to 2048 entries per packet, player-name checks are cached (about 80 times faster), and the Battle.net friend list is refreshed outside packet handling.
- Relay priority for large events: when a player's relay is saturated (for example a Horde–Alliance Battle.net bridge during a big battle), capture, keep, outpost, front, faction-call and commander messages are now sent before kills, rankings, history and economy data. Those can wait, since the periodic catch-up repairs them afterwards. The queue keeps its 128-packet bound; when it is full, an urgent message replaces the oldest waiting non-urgent one instead of being refused.

**Overlord Forever 1.0.22**

- Horde–Alliance relay: every beta packet now goes to all Battle.net friends of the opposite faction (up to five), who are the only bridges between factions. Previously each packet went to three Forever friends in rotation regardless of faction, so a bridge with several same-faction friends passed on only part of the traffic, delaying or losing capture alerts. Same-faction friends keep the remaining rotating slots, and a packet is no longer sent back to a friend who relayed it. No setting or extra friend is needed.

**Overlord Forever 1.0.21**

- Add Lesi Bear Cave, a new open-world guild outpost at Lunaclaw's cave in Darkshore (43.4 / 45.8). It works like Savix Chapel and Aeythyr Lodge: always open, held for 5 minutes by a guild member, contested only by the opposing faction. Players on older versions do not see it.

**Overlord Forever 1.0.20**

- Fix Battle.net synchronization between Forever players, including Horde–Alliance friends. Battle.net reports WoW Forever as project 18 while the beta client still reports project 1 (Retail), so Overlord skipped every Forever friend when sending, discarded their data when receiving, and spent its Battle.net slots on Retail friends instead. Leaderboards, captures, keeps and outposts can now cross factions through Battle.net friends again. Both players need this version.
- Keep the full leaderboard catch-up working without Communities. With no Overlord community available, the periodic digest catch-up had no peer to ask and never ran; it now uses the players discovered through the beta relay (channel, group and Battle.net, both factions). Only the peer choice changes; the exchange itself is unchanged.

**Overlord Forever 1.0.19**

- Fix leaderboard forgery through the beta relay. Only the last hop of a relayed message is authenticated by WoW/Battle.net, so an earlier origin written by a modified client can no longer credit kills, captures, Guild Keep points or an authoritative guild, and no longer puts the impersonated player in quarantine. Map, keep and outpost state are still relayed as before, and genuine scores still reach every player through ladder snapshots and catch-up.
- Remove the forged "Asmon Gold" row and its guild from the 2026-09-22 leaderboard, including saved copies and rows relayed back by older clients.
- Add `/ov network` (alias `/ov reseau`): a read-only 30-second count of incoming Overlord packets by transport and direct sender, without payloads or account identifiers.
- Keep the featured front activity list and Contracts button inside the panel when the text above takes more room, and leave space for the activity scroll bar.

**Overlord Forever 1.0.18**

- Remove the empty recent-activity message and its reserved space from the featured front panel so it no longer overlaps the Contracts button. Keep the activity title and combat rows.

**Overlord Forever 1.0.17**

- Show a one-time login warning that Communities and Battle.net are temporarily unavailable and Horde–Alliance data transfer may be unreliable. Use the existing yellow alert icon and remember the notice when displayed.

**Overlord Forever 1.0.16**

- Fix startup getting stuck on Contracts after the latest beta patch when UnitName no longer returns the full character name. Use the validated full name from GetUnitName so the main panel can open again.
- Show the current initialization step when the panel is unavailable instead of silently ignoring clicks and `/ov show`.
- Temporarily gray out and disable the Community button, hide the mandatory-community banner and joining prompts, and keep community synchronization and the fallback relay active.
- Keep the minimap button on the map border after login and minimap resizing, with support for rectangular and square minimaps and existing button collectors.
- Add regression coverage for complete player names, delayed identity availability and the Contracts login barrier.

**Overlord Forever 1.0.15**

- Add a special two-point Hillsbrad Foothills front between Southshore and Tarren Mill. Both towns have large capture circles, faction capitals and direct opposing-faction routes; the open-world map is distinct from the namesake battleground.
- Name the Redridge outpost Renosh Camp in all seven interface languages.
- Update the seven-language Forever guide, front names and map documentation. Cover the two towns, wide capture areas, map aliases and battleground exclusion in the location tests.

**Overlord Forever 1.0.14**

- Rewrite the tutorial for Forever in all seven interface languages, including layers, regional communication and the current objectives. Add Brazilian Portuguese and Simplified Chinese interface translations.
- Restore the Elwynn front and add the Lakeshire front in Redridge Mountains, with faction routes, map overlays and guild outposts. Add Aeythyr Lodge at Quel'Lithien Lodge in the Eastern Plaguelands. Remove the Stonewatch Guild Keep.
- Correct Night Run and the Hillsbrad mine locations. Place the Wetlands forest at 53.8, 43.7 and add the Ashenvale forest at 33.6, 63.6. Keep Mystral's capture point on its named south bank.
- Restore contextual indicator centering, adjust the main panel's default position and preserve manually moved panel positions across reloads, including through the native layout cache when the beta fails to load addon saves.
- Extend capture and map checks to all 57 control zones and add regression coverage for panel position persistence, scale changes and position reset.

**Overlord Forever 1.0.13**

- Raise the accepted synchronized kill total from 1,000 to 5,000 per player and campaign, inclusive. Reject higher totals instead of turning them into a capped score; keep local honorable-kill counting unchanged.
- Keep the top 500, background work slices, relay budgets and catch-up pacing unchanged.
- All participants need 1.0.13 or later to share totals above 1,000. Older clients still reject those totals; missing scores can return through the existing catch-up when an updated peer has retained them.
- Add regression coverage for live kills, leaderboard snapshots, additive guards and saved-score cleanup at the new boundaries.

**Overlord Forever 1.0.12**

- Align the kill leaderboard, peer catch-up and guild kill totals on the top 500 players. Keep aliases deduplicated, rank ties stable and capture rankings unchanged.
- Save the last displayed ranking so it can appear immediately after reconnecting. Refresh it in the background, and discard it when the campaign, data pool or cache format changes. The saved view never becomes an authoritative score source.
- Spread snapshot construction and network serialization across frames. Pace beta catch-up to one row per second while retaining the shared 1 KB/s relay budget and bounded queue. Older peers receive only the 200-row view they understand.
- Verify 500-player convergence through three relays, failed-enqueue retries, reload caching and a 10,000-player preparation workload.

**Overlord Forever 1.0.11**

**Overlord Forever 1.0.11**

- Expand the kill leaderboard to the top 5,000 players. Keep sorting spread across frames and render only visible rows; guild totals still include all known members.
- Open Guild Keeps every six hours, from 03:00–04:00, 09:00–10:00, 15:00–16:00 and 21:00–22:00 server time. Track reminders, capture proofs and victories separately for each siege while preserving historical captures and daily front rotation.
- Update Guild Keep synchronization for the new schedule. Players need this update to synchronize siege state with one another.
- Add Savix Chapel, an always-open guild outpost in Silverpine Forest at 61.8, 64.4.
- Restore Katrell's Retreat to its Retail coordinates, 40.3, 39.4, and rename the Ashenvale outpost to Shobek'Aran in all interface languages.
- Add coverage for siege boundaries, server timezones, successive captures, saved victories and the new outpost's capture area.

**Overlord Forever 1.0.10**

- Count outdoor Blizzard honorable kills once, without extra killing-blow, guessed-enemy or featured-front x2 credits. Keep the featured-front coin reward and preserve existing campaign totals.
- Sum guild totals across all known members, including players outside the top 200; preserve guild membership while the game API is still loading.
- Prevent third-party leaderboard relays and legacy pool merges from reassigning owner-confirmed guilds or factions and from clearing membership. Owner declarations can repair older relayed mistakes; confirmed departures remain protected after reload.
- Recheck unverified guilds with reachable owners, without duplicate queries or searching the beta mesh for offline characters.
- Rename the fictional mine currency to coins throughout all five interface languages, including HUD, map tooltips, notifications, costs and the featured front. Real gold contracts and donations retain their game-currency labels.
- Enforce the shared US beta campaign anchor, reject interrupted regional resets, and avoid a false weekly reset when SavedVariables did not load.
- Slice the full guild ranking sort and legacy settlement migration across frames. Add stress coverage for 10,000 players/guilds, 1,000 aliases and 5,000 historical settlements.

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
