$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$fixture = Join-Path $root ('_local/bridge-test-' + [Guid]::NewGuid().ToString('N'))
$addon = Join-Path $fixture 'Interface/AddOns/Overlord'
$saves = Join-Path $fixture 'WTF/Account/TEST#1/SavedVariables'
New-Item -ItemType Directory -Path (Join-Path $addon 'tools'), $saves -Force | Out-Null
$script = Join-Path $addon 'tools/Repair-ForeverSavedVariables.ps1'
Copy-Item -LiteralPath (Join-Path $root 'tools/Repair-ForeverSavedVariables.ps1') -Destination $script
$toc = Join-Path $addon 'Overlord.toc'
$save = Join-Path $saves 'Overlord.lua'
$initialToc = "## Interface: 16001`n## SavedVariables: OverlordDB`nCore.lua`nPopups.lua`n"
[IO.File]::WriteAllText($toc, $initialToc)
[IO.File]::WriteAllText($save, 'OverlordDB = { zones = { point = { owner = "Alliance" } } }')
$hash = (Get-FileHash -LiteralPath $save).Hash
& $script | Out-Null
if ((Get-FileHash -LiteralPath $save).Hash -ne $hash) { throw 'Installer modified the real save.' }
$installed = [IO.File]::ReadAllText($toc)
if ($installed.IndexOf('_local\SavedVariables\Overlord.lua') -lt $installed.IndexOf('Popups.lua')) {
    throw 'The save must load after all addon files.'
}

# Simulate WoW replacing the file at logout. A hard link would fail this case.
Move-Item -LiteralPath $save -Destination ($save + '.bak')
[IO.File]::WriteAllText($save, 'OverlordDB = { zones = { point = { owner = "Horde" } } }')
$linked = Join-Path $addon '_local/SavedVariables/Overlord.lua'
if ([IO.File]::ReadAllText($linked) -ne [IO.File]::ReadAllText($save)) {
    throw 'The bridge is loading an old file after rotation.'
}
& $script | Out-Null
if ([IO.File]::ReadAllText($toc) -ne $installed) { throw 'Repair is not idempotent.' }
$hash = (Get-FileHash -LiteralPath $save).Hash
& $script -Disable | Out-Null
if ([IO.File]::ReadAllText($toc).TrimEnd() -ne $initialToc.TrimEnd()) { throw 'Disable damaged the TOC.' }
if ((Get-FileHash -LiteralPath $save).Hash -ne $hash) { throw 'Disable modified the save.' }
if (-not (Test-Path -LiteralPath ($save + '.bak'))) { throw 'Recovery backup removed.' }

# Never pick another account silently.
$second = Join-Path $fixture 'WTF/Account/TEST#2/SavedVariables'
New-Item -ItemType Directory -Path $second -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $second 'Overlord.lua'), 'OverlordDB = {}')
$rejected = $false
try { & $script | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Ambiguous account selection accepted.' }
& $script -Account 'TEST#1' | Out-Null
$rejected = $false
try { & $script -Account 'TEST#2' | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw 'Existing bridge was silently rebound to another account.' }
Write-Output 'Forever bridge: live save, rotation, ordering, repair, disable, backups and account isolation OK.'
