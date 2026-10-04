1.5.0

**Overlord Forever 1.5.0**

- New **Layer Jumper** button (replaces the greyed Contracts slot, also `/ov layer`): see your layer in the current zone, list the zone's layers with available helpers, and jump to one (or press "Change layer" to go to any other one). An Overlord player on that layer invites you, the game moves you out of combat, then you leave the group automatically. Only volunteers act as helpers: "Help others" is off by default and, when on, invites automatically with no popup. Invisible addon messages only, nothing goes through the relay, and the number of helpers who answer adapts to the zone's crowd.
- Stronger protection of scores, captures and victories against forged data. Honest players are not affected: everyone still converges to the same ladder and the same map.
- Enemy-faction scores arrive much faster: totals from the other faction are caught up at once after a `/reload`, and a Battle.net friend of the other faction now shares its ranking with its cross-faction friends instead of staying busy with its own faction for a whole round.
- Very active players' scores are no longer under-counted.
- Enemy captures that stayed orange on your map now turn red.
- Capture and victory times use the server clock, so a PC running a few minutes ahead no longer overrides everyone else's map.
- Battle.net alerts of an active siege reach the other faction within a few seconds.
- Lighter network in crowds: Battle.net bridges skip copies another bridge already posted, raid members no longer re-send what the whole channel just heard, class/guild lookups get a few answers whatever the crowd size, and catch-ups after the weekly reset are spread out.
- Faster reload and logout: the saved leaderboard was written twice; the save file is about half its size.
- Launch-day performance: the player index no longer restarts from scratch each time a new player appears and never rebuilds during combat, and identical map snapshots received twice are skipped.
- No more red raid warning in the middle of the screen when a newer Overlord exists: the update notice stays in chat, once per session.
- The Next Objective panel keeps the main panel's height (its activity list shows as many rows as fit, at least two, and scrolls) and stays aligned with it. Overlord never moves your main panel on its own.
- Command moves up next to Call to arms; Tutorial sits next to Settings. The leaderboard shows the campaign ruleset right of the search box. The Hall of Fame tooltip no longer talks about gold donors only.
- `/ov network` shows more: Battle.net bridge activity, the neighbours the ladder catch-up can ask (by faction) and why the last round stopped (peer busy, no reply...).
- Cleanup of the Retail port: community (C_Club) transport, old bridges, RP realm auto-grouping and the Gilneas/Southern Barrens fronts are gone (about 5,000 lines). Nothing changes in game except the Community button, which stays greyed.
