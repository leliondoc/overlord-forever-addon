1.4.2

**Overlord Forever 1.4.2**

- Victories, scores and captures are harder to forge: a total victory applies only once your map shows the enemy capital taken (or from a group member); a player's total can only grow at a plausible pace (1 kill/s plus a small margin, and a 300-kill allowance for a name never seen that grows with the campaign age), never beyond what their level allows, whatever spelling of the name the packet uses; an owner flip of a quiet zone announced in a map snapshot needs a second source behind a different relay (or 5 minutes); a capturer finishes at most one zone per 25 s; future-dated captures no longer block the real ones. Everything is capped rather than refused, so honest players still converge to the same ladder, and suspicious senders are listed in `/ov network`. A modified client can still misreport its own level or forge the map of a zone nobody is watching: only a server could close those.
- Command moves up next to Call to arms; Tutorial sits next to Settings. The leaderboard shows the campaign ruleset right of the search box.
- Enemy captures that stayed orange on your map now turn red: the capture check accounts for the 15-60 s between cross-faction updates.
- Capture and victory times use the server clock, so a PC running a few minutes ahead no longer overrides everyone else's map.
- Lighter network in crowds: Battle.net bridges wait a few seconds and skip the channel copy when another bridge already posted it, raid members no longer re-send what the whole channel just heard, and class/guild lookups get about three answers whatever the crowd size.
- Faster reload and logout: the saved leaderboard was written twice; the save file is about half its size.
- Launch-day performance: the player index no longer restarts from scratch each time a new player appears, and identical map snapshots received twice are skipped.
- Cleanup of the Retail port: community (C_Club) transport, old bridges, RP realm auto-grouping and the Gilneas/Southern Barrens fronts are gone (about 5,000 lines). Nothing changes in game except the Community button, which stays greyed.
- `/ov network` reports the new counters (held and cancelled bridge copies, clamped totals, skipped snapshots), names the players whose total is pushed up by other senders above their own count and who sent it, and says when the ruleset had to be assumed.
- The Hall of Fame button tooltip no longer talks about gold donors only.
