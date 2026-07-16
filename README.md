# picd

A PowerShell command line to list pi workspaces and jump to one.

`picd` lists every directory that has a saved [pi](https://github.com/earendil-works/pi) session (newest first), fuzzy-picks one with [fzf](https://github.com/junegunn/fzf), and `Set-Location`s into it. Falls back to a numbered menu if fzf is missing.

## Install

Dot-source this file in your PowerShell profile:

```powershell
. "$env:USERPROFILE\.pi\agent\picd.ps1"
```

Then run:

```powershell
picd
```

Requires: PowerShell 5.1+ and `fzf` on `PATH` (optional; a numbered menu is used if absent).

## How it works

For each project directory under `~/.pi/agent/sessions`, it reads the first line (a JSON header) of any `.jsonl` session file to recover the original cwd verbatim — pi encodes the cwd into the session dir name by replacing `/ \ :` with `-`, which is ambiguous, so the header is used for accuracy. The project directory's own `LastWriteTime` is used as the recency timestamp.
