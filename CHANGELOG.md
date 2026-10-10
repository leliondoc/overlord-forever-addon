1.8.2

**Overlord Forever 1.8.2**

- **Update required**: every fix below only works on updated clients. A player still on 1.8.1 keeps the old behaviour (its map can stay behind for hours) until it updates. Updated players repair their own map from any neighbour on 1.7.0 or later.
- **Both factions see the same map again**: since 1.8.1 a capture you had missed could stay missing for hours, and Horde and Alliance could each keep their own version of a front (reported on Arathi). Several causes, all fixed:
  - **Points taken by a group**: when several players took a point and another one than the first finished the capture, other players saw the assault, then the point went back to its previous owner on their map. The capture now shows for everyone.
  - **A missed capture is always found again**: your client compares what its map holds with its neighbours' maps, zone by zone, instead of only looking at the newest capture. A capture you lack is asked for within a few minutes, and nothing is asked when the maps are equal.
  - **One front no longer blocks the whole map**: a capital taken on a front where the two factions disagreed on another zone made every map received be thrown away, on every front.
  - **Logging in or /reload no longer loses captures**: the first map received at login could replace newer captures you already knew with older ones. Captures you know are kept; newer ones are still learnt.
  - **A taken capital stays taken** when you log in or enter its front, even while the rest of that front is still catching up.
  - **The other faction's map is fetched even on a busy channel**: a Battle.net friend of the other faction is the only way to it, and requests to that friend were crowded out.
  - **A point both factions fight for**: when the other faction finished first and the player you were following finished afterwards, his capture was refused. It counts.
  - **A capture missed before an assault that was given up** on the same point could never be learnt again. It is.
- **Versions before 1.7.0 are no longer part of the map exchange (update required)**: such a client gave a conquered capital back to its faction 15 minutes after each truce. Its map is no longer asked for nor taken, and it is no longer served. `/ov network` says when one is heard.
- **World map, compact by default**: the compact display is now the default one, and each point's name is written inside its circle (a long name goes on along the bottom of the circle; the banner and the status still show under the mouse and while the point is being taken, and SYNCING stays written in the circle while your map is catching up). Everyone who shows Overlord on the map starts in the compact display once with this version; the full display with a banner on every point is one click away (Overlord button in the corner of the map, map Filters, options or `/ov map`) and your choice is then kept.
- **Keeps and outposts**: a keep or outpost capture you had missed is found again too (tenants are compared like zones).
- **Ranking between versions**: kills and captures are exchanged again between 1.8.0 and newer versions (only races are left out, 1.8.0 does not know the Skyborne race). Rankings no longer drift apart between versions, and keep and outpost captures made by players your version did not rank are accepted again.
- **Ranking window**: the sync indicator sits on the line of the campaign dates and of your rank; a Skyborne portrait no longer keeps the crop of another icon on a reused row.
- **/ov network**: says how many map requests were skipped (same map) or sent for a different map, counts keep and outpost refusals by cause, and tells for each Battle.net friend of the other faction what it can exchange.
