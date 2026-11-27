#!/usr/bin/env -S mise exec -- pwsh -NoProfile -File
param([string]$Score)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$env:ALDA_DISABLE_SPAWNING = 'yes'

$files = if ($Score) {
    Get-Item -LiteralPath $Score
} else {
    Get-ChildItem -LiteralPath songs -Filter *.alda -File -Recurse | Sort-Object FullName
}
if (-not $files) { return }

# Locate the state files using the installed player's own cache path and version.
$version, $logs = alda-player info
$cache = Split-Path -LiteralPath ($logs -replace '^log path: ')
$states = Join-Path $cache 'state/players' ($version -replace '^alda-player ')

function Wait-PlayerState($process, $state, $filter = '*.json') {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        foreach ($entry in Get-ChildItem -LiteralPath $states -Filter $filter -File -ErrorAction SilentlyContinue) {
            # The player rewrites the file in place. A partial read is not completion.
            try {
                $status = Get-Content -LiteralPath $entry.FullName -Raw -ErrorAction Ignore | ConvertFrom-Json
            } catch [IO.IOException], [ArgumentException] {
                continue
            }
            if ($status.state -ne $state -or -not $status.pid) { continue }
            # The Windows launcher reports its child JVM's PID in the state file.
            if ($status.pid -eq $process.Id -or (Get-Process -Id $status.pid -ErrorAction Ignore).Parent.Id -eq $process.Id) {
                return @{ Port = $status.port; File = $entry.Name }
            }
        }
        if ($state -eq 'ready' -and $timer.Elapsed.TotalSeconds -ge 30) {
            throw "Timed out waiting for Alda player $($process.Id) to become ready."
        }
    } while (-not $process.WaitForExit(250))
    throw "Alda player $($process.Id) exited before reporting '$state'."
}

$window = if ($IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} }
foreach ($file in $files) {
    Write-Host ([IO.Path]::GetRelativePath($PWD, $file.FullName))
    $process = Start-Process alda-player -ArgumentList run @window -PassThru
    $player = $null
    try {
        $player = Wait-PlayerState $process 'ready'
        alda play --port $player.Port -f $file.FullName
        $null = Wait-PlayerState $process 'finished' $player.File
    } finally {
        try {
            if ($player -and -not $process.HasExited) { alda shutdown --port $player.Port }
        } finally {
            if (-not $process.WaitForExit(2000)) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}
