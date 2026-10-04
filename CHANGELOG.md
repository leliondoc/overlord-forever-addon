1.5.1

**Overlord Forever 1.5.1**

- New **network health dot** in the main panel header, next to the version: green, orange or red in soft tones. Hover it for a summary of `/ov network` (Blizzard throttle, relay losses, ladder catch-up, relay queue). It only turns orange for what really affects you.
- New **Most Wanted**: the week's top five enemies get a skull in the kills ladder and on their nameplate (left of the health bar), and a chat alert with a skull tells you when one of them shows up near you (at most once per 10 min per player). `/ov wanted on|off` turns the nameplate skull and the alert off or back on. Never last week's players after the reset.
- **Fight size** in the Next Objective panel's "Recent activity": each front now shows how many kills happened there in the last 5 minutes (5+, 10+, 20+, 30+, 50+, 100+...), redder as the fight grows; below 5 kills it still shows how long ago. Fights **outside the fronts** are listed too, anywhere in the world (Stonetalon, Silithus...), with the zone name in your language and crossed swords, from 5 kills, three zones at most.
- The network dot, Most Wanted and the fight size send no network traffic: they only read what Overlord already receives. All three stop in instances and start fresh at the weekly reset.
- Live captures no longer freeze, restart or get cancelled while the capturer keeps going: observers follow the relay's real pace, your own capture progress and its final always get through, and big sieges send far fewer state requests.
- Friendly capture alerts only appear on the map of the front you are on (no more Elwynn alerts while you are in Redridge). Enemy captures are still announced on every front.
- Weekly reset: nothing from the past week survives the reset anymore, and a reset that was waiting behind an older archive now runs as soon as it can.
- Outposts remember who captured them (not displayed yet). The "suspicious outposts" list in `/ov network` is gone: it only ever showed relays.
- Shorter node names: Mystral Lake and The Loch lose their bank suffix, in every language.
- Stronger protection of captures and outposts against forged data.
