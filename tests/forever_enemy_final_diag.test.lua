-- 1.4.1 diagnostics (live: Horde captures seen in progress but not turning red on
-- Alliance maps): enemy capture finals are counted by outcome and shown in
-- /ov network. Counters only, own-faction finals are not counted.
assert(loadfile("tests/forever_beta_integration.test.lua"))()
local s = Overlord.Sync
Overlord.PlayerFaction = "Alliance"
s._enemyFinalStats = nil
assert(s:GetEnemyCaptureFinalDiagnostics():find("none received", 1, true))
s:NoteEnemyCaptureFinal("Horde", "C", "otherCapturer")
s:NoteEnemyCaptureFinal("Horde", "C", "otherCapturer")
s:NoteEnemyCaptureFinal("Horde", "ZS", "passed")
s:NoteEnemyCaptureFinal("Alliance", "C", "passed") -- own faction: not counted
s:NoteEnemyCaptureFinal(nil, "C", "passed")
local line = s:GetEnemyCaptureFinalDiagnostics()
assert(line == "Enemy capture finals (C / ZS captured): C otherCapturer 2, ZS passed 1.", line)
print("Enemy capture final diagnostics: counted by outcome, own faction ignored")
