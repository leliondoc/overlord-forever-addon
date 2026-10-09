1.8.0

**Overlord Forever 1.8.0**

- **Lighter ranking**: the ranking takes about a third less memory, and seeing new players no longer rebuilds the whole ranking index again and again (that was most of the memory shown for the addon and of its garbage-collection hitches). The full copy of last week's ranking is no longer kept for seven days; the weekly history of the best players stays.
- **Faster ranking catch-up between 1.8 players**: two updated players now exchange only the rows that differ instead of whole blocks of the ranking. A quiet round costs a single message each way, so rounds come more often and new totals spread to everyone sooner, with less network traffic.
- **Other faction sooner**: through a Battle.net friend of the other faction, only that faction's players are asked for (your own faction comes from your allies), then they spread to your allies at the next rounds.
- **New or lost save**: the best players of the ranking arrive first, in rank order, before the rest of the table.
- **Steadier catch-up on busy channels**: an exchange in progress no longer loses its neighbour when the channel is crowded.
- **Update recommended**: players on 1.7.x keep syncing with 1.8 as before, but only 1.8 players get the faster exchange.
- **Ranking back to the 1.7.5 rules**: the 1.7.6 changes are undone. Players who farm a lot right after the weekly reset are shown with their real total again; every protection from 1.7.5 stays.
- **Paused captures explained**: when your capture pauses because your PvP flag dropped or you mounted up, Overlord now tells you in chat what to do (the timer used to look frozen with no message).
- **Optional chat line on each honorable kill**: the "+N honorable kills: Total" line is back as an option (Options > AddOns > Overlord > Chat), off by default.
- **General is opt-in only again**: when the General dies or steps down, command no longer passes automatically to party or raid leaders who never pressed the General button.
