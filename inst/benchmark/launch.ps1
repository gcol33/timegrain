<#
.SYNOPSIS
Runs the timesift simulation benchmark detached, one Rscript worker per stripe of cells.

.DESCRIPTION
Point a Scheduled Task at this file so the run survives the shell that started it. Every worker
writes its own stdout and stderr log and its own PID file; the launcher writes DONE or FAILED when
every worker has exited. Replicates already on disk are skipped, so a killed run is restarted by
re-running the same command and costs at most the replicates that were in flight.

.EXAMPLE
schtasks /Create /TN "timesift_bench" /RL HIGHEST /F /SC ONCE /ST 23:59 /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\GillesC\Documents\dev\timesift\inst\benchmark\launch.ps1 -Block elasticnet -Workers 14"
schtasks /Run /TN "timesift_bench"
#>
[CmdletBinding()]
param(
  [ValidateSet('elasticnet', 'cnn', 'all')] [string] $Block = 'all',
  [ValidateSet('full', 'smoke')]        [string] $Scale = 'full',
  [string] $Cell = '',
  [string] $Reps = '',
  [int]    $Workers = 14,
  [string] $Out = '',
  [string] $Device = 'cpu',
  [string] $Rscript = 'C:\Program Files\R\R-4.6.1\bin\x64\Rscript.exe'
)

$ErrorActionPreference = 'Stop'
$bench = $PSScriptRoot
$repo = Split-Path (Split-Path $bench -Parent) -Parent
if (-not $Out) { $Out = Join-Path $repo 'benchmark-results' }
$runDir = Join-Path $Out ('_run_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
New-Item -ItemType Directory -Force -Path $Out | Out-Null

if (-not (Test-Path $Rscript)) { throw "Rscript not found at $Rscript" }
$env:TIMESIFT_DEVICE = $Device

# The cell list comes from design.R, never from a copy here, so the launcher cannot schedule a cell
# the runner does not recognise.
$listing = & $Rscript (Join-Path $bench 'run.R') "--scale=$Scale" '--list'
$cells = $listing | ForEach-Object {
  if ($_ -match '^\s*\d+\s+(\S+)\s+(\S+)\s') { [pscustomobject]@{ id = $Matches[1]; block = $Matches[2] } }
}
if ($Cell) { $cells = $cells | Where-Object { $_.id -eq $Cell } }
elseif ($Block -ne 'all') { $cells = $cells | Where-Object { $_.block -eq $Block } }
if (-not $cells) { throw "no cells matched Block=$Block Cell=$Cell Scale=$Scale" }

$ids = @($cells | ForEach-Object { $_.id })
$stripes = [Math]::Min($Workers, $ids.Count)
$plan = @()
for ($i = 0; $i -lt $stripes; $i++) {
  $mine = @()
  for ($j = $i; $j -lt $ids.Count; $j += $stripes) { $mine += $ids[$j] }
  $plan += ,$mine
}

@(
  "started      $(Get-Date -Format o)"
  "repo         $repo"
  "rscript      $Rscript"
  "scale        $Scale"
  "block        $Block"
  "device       $Device"
  "out          $Out"
  "cells        $($ids -join ', ')"
  "workers      $stripes"
) | Set-Content -Encoding utf8 (Join-Path $runDir 'launch.txt')

$procs = @()
for ($i = 0; $i -lt $stripes; $i++) {
  $mine = $plan[$i]
  if (-not $mine) { continue }
  # Rscript reports progress on stderr, and a PowerShell host started with -Command exits 1 when the
  # last native command wrote there whatever it returned. Each worker therefore carries its cells'
  # own exit codes forward, so a nonzero here means a cell failed rather than that a cell spoke.
  $steps = $mine | ForEach-Object {
    $a = @("`"$($bench)\run.R`"", "--scale=$Scale", "--cell=$_", "--out=`"$Out`"")
    if ($Reps) { $a += "--reps=$Reps" }
    '& "' + $Rscript + '" ' + ($a -join ' ') + '; if ($LASTEXITCODE -ne 0) { $fail = 1 }'
  }
  # A process started with redirected streams reports no ExitCode back to its parent, so the worker
  # states its own outcome in a file the launcher reads afterwards. A worker killed before it gets
  # there leaves no file, and a missing file counts as a failure.
  $status = Join-Path $runDir "worker$i.exit"
  $inner = '$fail = 0; ' + ($steps -join '; ') +
           '; Set-Content -Encoding utf8 -Path "' + $status + '" -Value $fail; exit $fail'
  # The worker command carries quoted paths, and Start-Process joins its argument list on spaces,
  # so it travels base64-encoded rather than as a string a second parser gets to reinterpret.
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))
  $p = Start-Process -FilePath 'powershell.exe' `
                     -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass',
                                     '-EncodedCommand', $encoded) `
                     -WorkingDirectory $repo `
                     -RedirectStandardOutput (Join-Path $runDir "worker$i.out.log") `
                     -RedirectStandardError  (Join-Path $runDir "worker$i.err.log") `
                     -WindowStyle Hidden -PassThru
  Set-Content -Encoding utf8 -Path (Join-Path $runDir "worker$i.pid") -Value $p.Id
  $procs += $p
}

$procs | ForEach-Object { $_.WaitForExit() }
$bad = 0
for ($i = 0; $i -lt $procs.Count; $i++) {
  $status = Join-Path $runDir "worker$i.exit"
  if (-not (Test-Path $status)) { $bad++; continue }
  if ([int]((Get-Content $status).Trim()) -ne 0) { $bad++ }
}
$marker = if ($bad -eq 0) { 'DONE' } else { 'FAILED' }
@(
  "finished     $(Get-Date -Format o)"
  "workers      $($procs.Count)"
  "nonzero exit $bad"
  "replicates   $((Get-ChildItem -Path $Out -Recurse -Filter 'rep_*.csv.gz' | Measure-Object).Count)"
) | Set-Content -Encoding utf8 (Join-Path $runDir $marker)
exit $bad
