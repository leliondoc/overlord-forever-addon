1.4.2

**Overlord Forever 1.4.2**

- Victories, scores and captures are harder to forge: a total victory applies only once your map shows the enemy capital taken (or from a group member), a suspicious jump in another player's total is capped instead of accepted, and future-dated captures no longer block the real ones.
- Enemy captures that stayed orange on your map now turn red: the capture check accounts for the 15-60 s between cross-faction updates.
- Capture and victory times use the server clock, so a PC running a few minutes ahead no longer overrides everyone else's map.
- Lighter network in crowds: Battle.net bridges wait a few seconds and skip the channel copy when another bridge already posted it, raid members no longer re-send what the whole channel just heard, and class/guild lookups get about three answers whatever the crowd size.
- Faster reload and logout: the saved leaderboard was written twice; the save file is about half its size.
- Launch-day performance: the player index no longer restarts from scratch each time a new player appears, and identical map snapshots received twice are skipped.
- Cleanup of the Retail port: community (C_Club) transport, old bridges, RP realm auto-grouping and the Gilneas/Southern Barrens fronts are gone (about 5,000 lines). Nothing changes in game except the Community button, which stays greyed.
- `/ov network` reports the new counters (held and cancelled bridge copies, clamped totals, skipped snapshots) and says when the ruleset had to be assumed.
