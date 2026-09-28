1.1.7

**Overlord Forever 1.1.7**

- Fortress map/minimap tooltips and the fortress HUD no longer show "Capturing..." indefinitely for expired remote observations. They fall back to the previous defender or the unclaimed presentation, consistently with the map icon. Fresh updates and locally controlled captures remain visible; this display correction does not change or broadcast capture ownership.

**Overlord Forever 1.1.6**

- Preserve the age of outpost and fortress observations restored at login. An observer returning after an assault no longer announces an inferred neutral state as a new event that can erase a capture completed while offline. Actual local abandons remain dated and synchronized.
- Retry refused broadcast forwards when another copy arrives through fragmented channel, group, whisper or Battle.net messages, without handling the event twice locally.

**Overlord Forever 1.1.5**

- Fortress pins show again on their zone maps (for example Wetlands), not only on the continent maps. Fortress captures measure your position on a map this client really has.
- An interrupted outpost or fortress capture that falls back to neutral now reaches every player who saw the assault start. Before, they could stay stuck on "capturing" for the aborted guild.
- Guild standings converge across factions: second-hand guild information now follows the most recent date, as on Retail, while a guild confirmed by the player or by a catch-up page stays protected. This fixes guild totals that differed between Horde and Alliance.
- Overlord no longer uses communities on Forever: data travels through the faction channel, groups and Battle.net bridges only. Presence is announced every 120 seconds instead of 45, and no longer resent after each capture.
- Relay: routine packets (outpost states, guild requests, raid alerts) can no longer wait behind presence until they expire, while presence keeps enough room to hold multi-hop routes. A capture, victory or reset event refused by a busy relay is forwarded when another copy arrives. Map replies no longer carry outposts and fortresses that were never captured.

**Overlord Forever 1.1.4**

- Fortresses now use the same capture, contest, decay and ownership rules as outposts. Their locations, existing icons and separate leaderboard column remain; their base capture time is 10 minutes instead of 5. Captures are available at any time, with ownership lasting until recapture or campaign reset.
- **Fortress migration:** the old siege schedule, daily victory/proof system and its saved data are removed on first load. Fortresses start neutral and their old daily standings are cleared; the separate fortress column now counts captures. Existing outpost states and scores, and player kill scores, are preserved. Other players need this update to participate in the new fortress system.
- Remove the old fortress network messages and daily-proof responses, including those previously generated for older clients' full sync requests. Fortress state and ranking now travel through the existing outpost protocols and catch-up.
- Add negotiated V6 leaderboard catch-up for kills, captures and race metadata, with resumable stream/bucket checkpoints. Updated peers advertise support; older peers retain V5 kills and legacy fallback. A silent first request is retried within a bounded deadline. Leaderboard catch-up is still being monitored in live play: this release does not guarantee that every bridge or older peer will answer.
- Keep map catch-up, ranking pages and domination/victory snapshots progressing within the existing 1,000 B/s shared relay budget. Reserve bounded queue capacity, defer paged producers under pressure, coalesce duplicate pending map requests and allow ready relay copies to pass blocked ones. Expire fragmented transfers by inactivity within their overall lifetime.
- Reduce repeated leaderboard rebuilds and metadata scans while updates arrive with the panel open. Preserve newer guild metadata, including guild departures, when merging solicited ranking snapshots.
- Merge domination snapshots consistently and retain bounded pending victory bonuses until the required victory/state evidence arrives, without crediting repeated events twice.
- Add optional enemy guild raid alerts based on recent authenticated kill observations, with thresholds, bounded tracking, deduplication and a settings toggle. Live capture and commander alerts retain their existing transport paths.
- Label the Hillsbrad front consistently, clarify the floating coins-panel setting, and add an optional floating Next Objective guide. The regular objective panel remains available and settings scroll to cover all options.

**Overlord Forever 1.1.3**

- Add a local player/guild search at the top left of the leaderboard, with debounced and sliced filtering, cached results, original ranks and unchanged faction totals. Accented Latin and Cyrillic names match regardless of case. No network queries or new art assets.
- Next Objective keeps its full map picture and five-row recent activity viewport on short two-point fronts. Its minimum height reserves space for wrapped guidance and coins instead of compressing the activity card and scrollbar. The dock is clamped to the screen and follows main-panel height changes.

**Overlord Forever 1.1.2**

- Remove the remaining floating Capture Zone window during regular captures, including manual HUD commands. Distance, instructions and progress remain in the Next Objective side panel; keep/outpost HUDs and automatic map waypoints remain available.

**Overlord Forever 1.1.1**

- Paged catch-up diagnostics no longer say "receiving" before any reply. They distinguish preparation, a request waiting to enter the send queue, waiting for a peer, page reception and application, with fragment counts, the remaining response timeout and combat/instance pauses.
- Layer tooltips and invitation lists now use recently observed player/Battle.net factions instead of historical ranking metadata. Unknown factions are neutral grey instead of red, including reused invitation buttons. Existing bounded caches are reused, with no additional network packets.
- The floating Next Objective banner is removed. The side panel now shows Next Objective in its title ribbon, the current front's picture and the next objective's name underneath, followed by distance, capture instructions, progress and contested/paused state. Details refresh on the existing one-second UI tick, with room reserved above recent activity. Capture timers and the automatic map waypoint remain available; hidden panels do no objective refresh work.
- Addressed leaderboard catch-up now has 16 protected queue slots and a 300 B/s service share inside the existing 1,000 B/s relay budget. Requests, acknowledgements and ranking data can progress through busy bridges without waiting for all presence and alerts to stop. The full queue stays bounded to 128 packets; old transfers can borrow idle slots, and unused bandwidth remains available to other traffic.
- Fewer redundant presence copies: when a peer sends back the exact same signal, its still-pending personal copy is skipped. A newer unsent signal replaces the older one in place. The 90-second forwarding interval and five-minute peer lifetime are unchanged; `/ov network` reports these savings and the reserved catch-up queue.
- Guild keep proofs cost far less CPU: the same proof reaches you through several relays, and each copy was fully re-validated (about 2.5 ms) before being recognised as already known. An identical, already processed proof is now dropped at once while the keep's state is unchanged; any change still goes through the full check.
- Less load on Battle.net bridges: kills are no longer re-forwarded past their author's first hop, since a relayed kill is never credited anyway (anti-forgery). With regular 45-second heartbeats, only one in two presence signals is re-forwarded, using the player's emission timestamp instead of the local arrival time. Tests cover an isolated loss and variable transit delays; the earlier bridge measurement attributed about 95% of relay bytes to presence.
- Smoother frames during map syncs: ordering a received map snapshot looked up the same zone information hundreds of times (up to ~5 ms in one frame). It is now computed once per zone, with exactly the same order.
- The front map lookup, used thousands of times a minute by the minimap, HUD and sync, is now remembered per front instead of querying the game's map data every time.

**Overlord Forever 1.1.0**

- Outpost and guild keep ranking rows now keep the site name aligned: the held-site icon uses a fixed size instead of the image's native size, which made names jump left on some rows.
- Coins now live in a dedicated Featured Front panel: the balance sits above two wider Reinforce and Attack buttons, with their cost and a ready indicator. Unavailable actions are greyed out and hidden panels do no refresh work (the optional top coins panel remains available in settings).
- The player ranking now displays up to 5,000 known players. Guild and faction totals include every locally known player, with aliases counted once, so falling out of the displayed ranking no longer subtracts a member's kills. Rendering stays limited to visible rows, with sorting and local snapshots built in slices. Updated peers also recover up to 5,000 players through resumable, identity-based pages; older peers retain the compatible top-500 exchange.
- Paged catch-up compares 64 identity buckets, transfers at most 16 scores per page, verifies complete pages before applying the existing score filters, and resumes incomplete buckets after disconnects. Unchanged buckets are skipped. A shared 300 B/s estimated wire budget, relay backpressure, combat/instance pauses and sliced work protect live traffic and frame time. `/ov network` reports page progress and filtered rows.
- Quota-blocked relay copies now wait without being recreated every tick or discarded after 30 polls. Ready Battle.net traffic can pass waiting copies in either priority lane.
- Less clutter during fights: the floating Overlord panels fade to 40% while you are in combat, and the "Next objective" guide is shown at 60% opacity. Capture progress inside a zone stays fully visible out of combat.
- Cross-faction leaderboard catch-up now asks the other faction's player with the shortest route first (your own Battle.net friend when you have one), and recognises the faction of Battle.net friends. Long relay routes were losing the answers.

**Overlord Forever 1.0.34**

- The other faction's leaderboard scores now refresh every 10 to 20 minutes instead of 40 to 60. After receiving a leaderboard, Overlord sends its own back and used to wait up to 20 minutes for a confirmation that rarely arrives through a Battle.net bridge, then start a whole new exchange. It now waits 4.5 minutes and moves on; both sides have already merged the lines. Two catch-up rounds out of three now ask a player of the other faction first, since your own faction is already up to date live.
- Replaces 1.0.33, whose package was never published (the settings file failed to load).
- The coins panel (coins counter with Reinforce and Attack at the top of the screen) is now off by default. Turn on "Coins panel" in the Overlord settings to show it again.

**Overlord Forever 1.0.32**

- New "Overlord zones" checkbox in Blizzard's Map Filters menu on the world map: untick it to hide every Overlord display on the world map (zones, paths, keeps, outposts, mines, forests, General), tick it to bring them back. While hidden, Overlord does no map work at all. `/ov map` does the same.
- Capture zones on the minimap now default to 50% opacity instead of a full red/blue plate. Existing installs are moved to 50% once; set it back to 100% in the settings if you prefer.

**Overlord Forever 1.0.31**

- The realm channel now only carries what it can: on Forever, Blizzard accepts about one addon message per second per player on a channel, and Overlord was sending far more, so most messages (alerts included) were refused. The channel now keeps capture, capture-in-progress, victory, attack and siege alerts, presence and sync requests, paced at under one message per second.
- Guild keeps and outposts are now the lowest priority everywhere: in the relay (Battle.net, whispers) only a siege in progress and the rare final events (keep or outpost taken, assault started) stay ahead; routine keep and outpost updates wait behind captures and alerts.
- Removed from the channel (they were almost always refused): guild keep and outpost bookkeeping outside a siege in progress, keep proofs, outpost counters, leaderboard lines and full map snapshots. They still arrive through the raid and the targeted catch-ups.
- Your own kill total goes on the channel at most every 30 seconds (the latest total is always sent at the end of the window). Your raid still gets every kill live.
- New map catch-up every two and a half to three minutes: Overlord asks one player (every other time from the other faction) for the zone state, so the map is right within a few minutes even when live alerts are lost.
- `/ov network` shows channel use per message type, the catch-up's last step and skipped channel copies.

**Overlord Forever 1.0.30**

- Fixed the "Error module ManualBountyUI" message shown at login since 1.0.29: the disabled gold-contract interface was still initialized.

**Overlord Forever 1.0.29**

- Gold contracts are disabled on Overlord Forever: their modules are no longer loaded (lighter addon), the Contracts button is greyed out, no wax seal is shown on the maps, contract messages from older versions are ignored, and an open contract no longer prevents anyone from becoming General.
- The leaderboard catch-up now actually brings in the other faction's scores. Three problems kept it from working through Battle.net bridges: a player who never answered blocked it for 20 minutes before the next one was tried (now 4.5 minutes); a transfer that lost even a few lines on the way was restarted at once, up to four times in a row, which saturated the bridge and never finished (the lines received are kept and the next round follows about two minutes later); and every other round now asks a player of the other faction first, since allies share the same gap. The protocol and the acceptance rules are unchanged.
- Packets refused by Blizzard's addon throttle are no longer lost silently. Overlord ignored the result of each send: when the realm channel was saturated, a kill, capture or relay fragment was dropped while being counted as sent, so two players of the same faction could see slightly different totals. A refused send is now reported, and relay copies are retried (at most three times) without holding back the Battle.net copies.
- Much less traffic on the realm channel, so fewer sends hit Blizzard's throttle during big fights:
  - In a raid, each member no longer re-sends on the channel every packet it received from the raid when that packet was already on the channel. In a 40-player raid, one kill could go out on the channel up to about 39 times.
  - Kills (K, EK) and sync requests (SR) no longer go out twice (a direct copy inherited from Retail plus the relay's copy). For sync requests this also restores the intended limit of about three answering players; the direct copy made about 95% of the channel answer every request.
  - The old bridge announcements (ST), replaced by the relay, are no longer sent.
- `/ov network` now also shows the state of the leaderboard catch-up (requests, completed rounds, lines received, last player asked and result), relay counters and sends refused by Blizzard.
- The Redridge front is now listed by its zone name (Redridge Mountains / Les Carmines / ...) instead of the town of Lakeshire, like the other fronts.
- Translated the standalone outpost names (Savix Chapel, Aeythyr Lodge, Lesi Bear Cave) in every language, and fixed a few English leftovers in French, Spanish and German (Hall of Fame, Export, WANTED...).
- Brazilian Portuguese: bounty COD invoices sent by Portuguese clients are recognized again (their mail subject had been translated, so the signer never matched it).
- Brazilian Portuguese and Simplified Chinese: fixed many machine-translation errors (kills column, keep, class, race, Discord, disabled/auto toggles, layer terms, guild keep messages) and translated the tutorial texts that were still in English.

**Overlord Forever 1.0.28**

- Fewer frame drops in large fights: a raid kill no longer triggers an immediate scan of every nameplate to find the layer (shard); kills are grouped with the other layer checks into one scan per burst. When many allied players appear at once, the raid catch-up no longer rebuilds the 40-member roster for every nameplate while its message budget is exhausted.
- Removed about 1,500 lines of unused code inherited from Retail Overlord (functions no longer called anywhere). No behaviour change.

**Overlord Forever 1.0.27**

- Guild keep siege wins are now fully checked only when needed: once after login, then once when each siege ends (every six hours). Between sieges nothing is recomputed. Proofs received from other players already update their own keep right away, in the background, so no win is lost; the regular re-checks every thirty seconds or ten minutes are gone.

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
