2.3.1

**Overlord Forever 2.3.1**

- No more "You're doing that too fast" caused by the addon: while the game refuses the Overlord channel, the server still let the addon in for a moment before refusing its messages, and 2.3.0 took that for a success and tried the channel again every minute with several channel joins and leaves. A channel that refuses the addon's messages now counts as refused, is tried again with a single join, less and less often (up to every 15 minutes), and this is remembered after a /reload or a login.
- The addon no longer joins temporary channels at all (they only placed the Overlord channel's number in your list). It still waits for the game's own channels before joining, so their numbers and colours do not move.
- /ov network: the channel line no longer says it is tried again every 5 minutes.
