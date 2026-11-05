2.1.1

**Overlord Forever 2.1.1**

- **Addon channel**: since the launch the game refuses addon messages on custom channels, and Overlord went on talking to nobody behind a green dot. It now notices, says so in the network panel (/ov network), and tries the channel again every 5 minutes: as soon as the game reopens it, everything goes back by itself.
- **Guild**: while the channel is refused or nobody answers on it, your presence and captures go through your guild, a few messages at most; maps and rankings then travel by whisper between guild mates. Nothing goes there while the channel works and others are heard on it. /ov guild off stops your own guild messages.
- Without a guild, data only reaches you through your group and your Battle.net friends until the channel reopens. Group search stays unavailable while the channel is refused.
- **Options search**: typing in the search box of the game's Options no longer raises an error saying that Overlord tried to call a protected function. Overlord's two buttons on its options page (action bar shortcut, chat tab) are no longer listed by that search.
- Plays alongside 2.1.0: nothing changes for it, but a 2.1.0 client does not read the guild.
- **Restart the game after updating** (a new file: a /reload is not enough).
