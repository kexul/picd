# picd — pick a pi session's cwd and Set-Location into it.
#
# Dot-source this file in your PowerShell profile:
#   . "$env:USERPROFILE\.pi\agent\picd.ps1"
# Then run `picd`.
#
# Lists every directory that has a saved pi session (newest first, by the
# latest session file in each dir), fuzzy-picks one with fzf, and cd's there.
# Requires: fzf on PATH. Falls back to a numbered menu if fzf is missing.

function picd {
    [CmdletBinding()]
    param(
        [string]$SessionsDir = (Join-Path $env:USERPROFILE ".pi\agent\sessions")
    )

    if (-not (Test-Path $SessionsDir)) {
        Write-Error "picd: no sessions dir: $SessionsDir"
        return
    }

    # Build a list of [PSCustomObject] with Cwd + When, one per project dir.
    #
    # Performance notes: there can be hundreds of session files across dozens
    # of project dirs. Instead of enumerating+sorting files inside every dir
    # (one stat per file), we:
    #   * use the project dir's own LastWriteTime as the recency timestamp
    #     (it bumps whenever pi creates a new session file in it), and
    #   * read only the first .jsonl we find in the dir for its cwd header —
    #     all sessions in a dir share the same cwd (the dir name is derived
    #     from it), so any file suffices.
    # This avoids touching every file and is ~3x faster on large session sets.
    $rx = [regex]'"cwd"\s*:\s*"([^"]+)"'
    $projects = foreach ($dir in [System.IO.Directory]::EnumerateDirectories($SessionsDir)) {
        $di = [System.IO.DirectoryInfo]::new($dir)
        $first = $null
        foreach ($f in [System.IO.Directory]::EnumerateFiles($dir, '*.jsonl')) { $first = $f; break }
        if (-not $first) { continue }

        $cwd = $null
        try {
            # ReadLine() reads only the first line; ReadAllLines() would load
            # the whole (potentially large) session file just to grab the header.
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
        [PSCustomObject]@{ Cwd = $cwd; When = $di.LastWriteTime }
    }

    if (-not $projects) {
        Write-Error "picd: no sessions found in $SessionsDir"
        return
    }

    $ordered = $projects | Sort-Object When -Descending
    $choices = $ordered | ForEach-Object { $_.Cwd }

    $pick = $null
    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        $pick = $choices | fzf --prompt="pi cwd> " --reverse
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
