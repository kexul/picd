# picd — pick a pi session's cwd and Set-Location into it.
#
# Dot-source this file in your PowerShell profile:
#   . "$env:USERPROFILE\.pi\agent\picd.ps1"
# Then run `picd`.
#
# Lists every directory that has a saved pi session (newest first, by the
# project dir's LastWriteTime), fuzzy-picks one with fzf, and cd's there.
# Requires: fzf on PATH. Falls back to a numbered menu if fzf is missing.
#
# Performance notes:
#   * Results are cached in ~/.pi/agent/picd-cache.txt, one line per project
#     dir: "dirName<TAB>lastWriteTicks<TAB>cwd" (empty cwd = dir has no
#     sessions, skip it). A dir's LastWriteTime bumps whenever pi creates a
#     new session file in it, so comparing ticks is enough to invalidate:
#     on a cache hit we never enumerate or open any session files at all,
#     we just stat the project dirs (~80 dirs -> ~15ms instead of ~80ms).
#   * fzf is probed once per shell session, not once per call.
#   * Sorting uses List<T>.Sort instead of the Sort-Object pipeline.

# $false = not probed yet; $null = probed, missing; path string = probed, found
$script:__picdFzf = $false
$script:__picdCache = $null   # Dictionary[string,string] name -> "ticks`tcwd"

function picd {
    [CmdletBinding()]
    param(
        [string]$SessionsDir = (Join-Path $env:USERPROFILE ".pi\agent\sessions")
    )

    if (-not [System.IO.Directory]::Exists($SessionsDir)) {
        Write-Error "picd: no sessions dir: $SessionsDir"
        return
    }

    $cachePath = Join-Path $env:USERPROFILE ".pi\agent\picd-cache.txt"

    # Load the cache (first call in this shell only).
    if ($null -eq $script:__picdCache) {
        $script:__picdCache = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
        if ([System.IO.File]::Exists($cachePath)) {
            foreach ($l in [System.IO.File]::ReadLines($cachePath)) {
                $tab = $l.IndexOf("`t")
                if ($tab -gt 0) {
                    $script:__picdCache[$l.Substring(0, $tab)] = $l.Substring($tab + 1)
                }
            }
        }
    }
    $cache = $script:__picdCache

    $rx = [regex]'"cwd"\s*:\s*"([^"]+)"'
    $dis = [System.Collections.Generic.List[System.IO.DirectoryInfo]]::new()
    foreach ($d in [System.IO.Directory]::EnumerateDirectories($SessionsDir)) {
        $dis.Add([System.IO.DirectoryInfo]::new($d))
    }

    $changed = $false
    $cwdByName = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $newCache = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($di in $dis) {
        $ticks = "$($di.LastWriteTime.Ticks)"
        $cwd = $null
        $fresh = $false
        $hit = $null
        if ($cache.TryGetValue($di.Name, [ref]$hit)) {
            $tab = $hit.IndexOf("`t")
            if ($tab -ge 0 -and $hit.Substring(0, $tab) -ceq $ticks) {
                $cwd = $hit.Substring($tab + 1)   # '' => known: no sessions here
                $fresh = $true
            }
        }
        if (-not $fresh) {
            $cwd = ''
            # Read the "cwd" header from the first .jsonl in the dir (any file
            # works; all sessions in a dir share the same cwd). ReadLine()
            # reads only the first line, not the whole session file.
            $first = $null
            foreach ($f in [System.IO.Directory]::EnumerateFiles($di.FullName, '*.jsonl')) { $first = $f; break }
            if ($first) {
                try {
                    $sr = [System.IO.StreamReader]::new($first, [System.Text.Encoding]::UTF8)
                    try { $line = $sr.ReadLine() } finally { $sr.Dispose() }
                    $m = $rx.Match($line)
                    if ($m.Success) {
                        # unescape JSON string escapes that appear in paths
                        $cwd = $m.Groups[1].Value -replace '\\\\', '\' -replace '\\/', '/'
                    }
                } catch {}
                if (-not $cwd) {
                    # fallback: decode dir name (may be wrong on paths containing -)
                    $inner = $di.Name -replace '^--', '' -replace '--$', ''
                    if ($inner -match '^([A-Za-z])--(.*)$') {
                        $cwd = "$($Matches[1]):/$($Matches[2] -replace '-','/')"
                    } else {
                        $cwd = '/' + ($inner -replace '-','/')
                    }
                }
            }
            $changed = $true
        }
        $newCache[$di.Name] = "$ticks`t$cwd"
        if ($cwd.Length -gt 0) { $cwdByName[$di.Name] = $cwd }
    }
    $script:__picdCache = $newCache

    if ($cwdByName.Count -eq 0) {
        Write-Error "picd: no sessions found in $SessionsDir"
        return
    }

    # Persist if anything changed (new/touched dirs) or dirs were deleted.
    if ($changed -or $cache.Count -ne $dis.Count) {
        $lines = [System.Collections.Generic.List[string]]::new($newCache.Count)
        foreach ($k in $newCache.Keys) { $lines.Add("$k`t$($newCache[$k])") }
        try { [System.IO.File]::WriteAllLines($cachePath, $lines.ToArray()) } catch {}
    }

    # Newest first (project dir LastWriteTime bumps when pi creates a session).
    $dis.Sort([System.Comparison[System.IO.DirectoryInfo]]{ param($a, $b) $b.LastWriteTime.CompareTo($a.LastWriteTime) })
    $choiceList = [System.Collections.Generic.List[string]]::new($cwdByName.Count)
    foreach ($di in $dis) {
        $c = $null
        if ($cwdByName.TryGetValue($di.Name, [ref]$c)) { $choiceList.Add($c) }
    }
    $choices = $choiceList.ToArray()

    # Probe fzf once per shell session.
    if ($script:__picdFzf -eq $false) {
        $script:__picdFzf = try { (Get-Command fzf -ErrorAction Stop).Source } catch { $null }
    }

    $pick = $null
    if ($script:__picdFzf) {
        $pick = $choices | & $script:__picdFzf --prompt="pi cwd> " --reverse
    } else {
        # numbered menu fallback
        Write-Host "Recent pi project directories:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $choices.Count; $i++) {
            Write-Host ("{0,3}. {1}" -f ($i + 1), $choices[$i])
        }
        $sel = Read-Host "Select number"
        if ($sel -match '^\d+$' -and [int]$sel -ge 1 -and [int]$sel -le $choices.Count) {
            $pick = $choices[[int]$sel - 1]
        }
    }

    if (-not $pick) { return }

    if (-not (Test-Path -LiteralPath $pick)) {
        Write-Error "picd: not a directory: $pick"
        return
    }

    Set-Location -LiteralPath $pick
    Write-Host "-> $pick" -ForegroundColor Green
}
