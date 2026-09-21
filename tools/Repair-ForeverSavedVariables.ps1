# Local workaround for the Forever beta SavedVariables loader.
# Reads the live account file through an NTFS directory junction; never writes WTF.
[CmdletBinding()]
param(
    [string] $Account,
    [switch] $Disable
)

$ErrorActionPreference = 'Stop'
$addonRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$tocPath = Join-Path $addonRoot 'Overlord.toc'
$localRoot = Join-Path $addonRoot '_local'
$linkPath = Join-Path $localRoot 'SavedVariables'
$beginMarker = '# BEGIN OVERLORD LOCAL SAVEDVARIABLES'
$endMarker = '# END OVERLORD LOCAL SAVEDVARIABLES'
$bridgePattern = '(?ms)^' + [regex]::Escape($beginMarker) + '\r?\n.*?^' + [regex]::Escape($endMarker) + '(?:\r?\n|$)'
$utf8 = New-Object Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $tocPath -PathType Leaf)) {
    throw 'Run this script from the installed Overlord/tools folder.'
}
$toc = [IO.File]::ReadAllText($tocPath)
if ($toc -notmatch '(?m)^## Interface: 16001\s*$' -or
    $toc -notmatch '(?m)^## SavedVariables: OverlordDB\s*$') {
    throw 'This workaround only supports Overlord Forever (Interface 16001, OverlordDB).'
}
if ($toc -match '(?m)^## LoadSavedVariablesFirst: 1\s*$') {
    throw 'Unexpected loading order; the bridge must load after the addon files.'
}
if (($toc.Contains($beginMarker) -or $toc.Contains($endMarker)) -and
    -not [regex]::IsMatch($toc, $bridgePattern)) {
    throw 'Incomplete local bridge block in Overlord.toc; no files were changed.'
}
$cleanToc = [regex]::Replace($toc, $bridgePattern, '')

if (Test-Path -LiteralPath $localRoot) {
    if ((Get-Item -LiteralPath $localRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw '_local must be a real directory inside Overlord.'
    }
}

if (-not $Disable) {
    # Overlord -> AddOns -> Interface -> client root.
    $clientRoot = [IO.Path]::GetFullPath((Join-Path $addonRoot '../../..'))
    $accountsRoot = Join-Path $clientRoot 'WTF/Account'
    $accounts = @(Get-ChildItem -LiteralPath $accountsRoot -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SavedVariables/Overlord.lua') -PathType Leaf
    })
    if ($Account) {
        $accounts = @($accounts | Where-Object { $_.Name -eq $Account })
    }
    if ($accounts.Count -ne 1) {
        throw 'Select exactly one account with -Account "ACCOUNT#1". It must already have an Overlord.lua save.'
    }
    $sourceDirectory = Join-Path $accounts[0].FullName 'SavedVariables'
    $sourcePath = Join-Path $sourceDirectory 'Overlord.lua'
    if ([IO.File]::ReadAllText($sourcePath) -notmatch '(?m)^OverlordDB\s*=\s*\{') {
        throw 'The save does not contain an OverlordDB table; no files were changed.'
    }
    if (Test-Path -LiteralPath $linkPath) {
        $existing = Get-Item -LiteralPath $linkPath -Force
        if ($existing.LinkType -ne 'Junction' -or
            [IO.Path]::GetFullPath([string]$existing.Target) -ne [IO.Path]::GetFullPath($sourceDirectory)) {
            throw 'The existing bridge targets a different directory. No account data was changed.'
        }
    }
}

# Back up before changing the local loader. These files stay outside Git/packages.
New-Item -ItemType Directory -Path $localRoot -Force | Out-Null
$backupRoot = Join-Path $localRoot ('backup-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $backupRoot | Out-Null
Copy-Item -LiteralPath $tocPath -Destination (Join-Path $backupRoot 'Overlord.toc')
if (-not $Disable) {
    foreach ($suffix in @('', '.bak', '.capture-backup')) {
        $candidate = $sourcePath + $suffix
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            Copy-Item -LiteralPath $candidate -Destination (Join-Path $backupRoot ('Overlord.lua' + $suffix))
        }
    }
    if (-not (Test-Path -LiteralPath $linkPath)) {
        New-Item -ItemType Junction -Path $linkPath -Target $sourceDirectory | Out-Null
    }
    # A directory junction follows the NEW file when WoW rotates .lua to .lua.bak.
    # A hard link or a one-time copy would keep loading an obsolete capture.
    $newline = if ($toc.Contains("`r`n")) { "`r`n" } else { "`n" }
    $newToc = $cleanToc.TrimEnd("`r", "`n") + $newline + $newline +
        $beginMarker + $newline + '_local\SavedVariables\Overlord.lua' + $newline +
        $endMarker + $newline
} else {
    $newToc = $cleanToc
}

$tempToc = Join-Path $addonRoot 'Overlord.toc.tmp'
[IO.File]::WriteAllText($tempToc, $newToc, $utf8)
Move-Item -LiteralPath $tempToc -Destination $tocPath -Force
if ($Disable) {
    Write-Output 'Local bridge disabled. SavedVariables and recovery backups were preserved.'
} else {
    if ((Get-FileHash -LiteralPath (Join-Path $linkPath 'Overlord.lua')).Hash -ne
        (Get-FileHash -LiteralPath $sourcePath).Hash) {
        throw 'Bridge verification failed. Re-run with -Disable before starting WoW.'
    }
    Write-Output 'Local bridge installed and verified. No background process is required.'
}
Write-Output "Backup: $backupRoot"
Write-Output 'Fully exit and restart WoW before testing a capture, /reload, and another character.'
