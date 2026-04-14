# createjunctions.ps1
# Creates directory junctions from a workspace folder into a source folder.
# The junction is named after the last segment of each project path.
#
# Usage:
#   .\createjunctions.ps1 -WorkspaceRoot "C:\...\MyWorkspace" -SourceRoot "C:\...\Git" -Projects "RepoA","RepoB"
#
# Subfolder example (junction named "MyComponent" pointing deep into a monorepo):
#   .\createjunctions.ps1 ... -Projects "RepoA","BigRepo\src\MyComponent"
#
# To remove a junction safely: Remove-Item <junction-path>   (never use -Recurse on a junction)

param(
    [Parameter(Mandatory)][string]   $WorkspaceRoot,
    [Parameter(Mandatory)][string]   $SourceRoot,
    [Parameter(Mandatory)][string[]] $Projects
)

if (-not (Test-Path $WorkspaceRoot -PathType Container)) {
    Write-Error "WorkspaceRoot does not exist: $WorkspaceRoot"
    exit 1
}

if (-not (Test-Path $SourceRoot -PathType Container)) {
    Write-Error "SourceRoot does not exist: $SourceRoot"
    exit 1
}

# Resolve to absolute paths — New-Item Junction requires absolute target paths
$WorkspaceRoot = (Resolve-Path $WorkspaceRoot).Path
$SourceRoot    = (Resolve-Path $SourceRoot).Path

# Detect name collisions before doing any work
$names = $Projects | ForEach-Object { Split-Path $_ -Leaf }
$duplicates = $names | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name
if ($duplicates) {
    foreach ($dup in $duplicates) {
        Write-Error "Name collision: multiple projects resolve to '$dup'. Disambiguate by renaming the entries."
    }
    exit 1
}

$hadErrors = $false
foreach ($entry in $Projects) {
    $junctionName = Split-Path $entry -Leaf
    $junctionPath = Join-Path $WorkspaceRoot $junctionName
    $targetPath   = Join-Path $SourceRoot $entry

    if (-not (Test-Path $targetPath -PathType Container)) {
        $stale = Get-Item $junctionPath -Force -ErrorAction SilentlyContinue
        if ($stale -and $stale.LinkType -eq 'Junction') {
            Write-Warning "Target does not exist: $targetPath`n  Stale junction at $junctionPath — remove with: Remove-Item '$junctionPath'"
        } else {
            Write-Warning "Target does not exist, skipping: $targetPath"
        }
        $hadErrors = $true
        continue
    }

    if (Test-Path $junctionPath) {
        $existing       = Get-Item $junctionPath -Force
        $existingTarget = $existing.Target | Select-Object -First 1
        if ($existing.LinkType -eq 'Junction' -and $existingTarget.TrimEnd('\') -eq $targetPath.TrimEnd('\')) {
            Write-Host "Already exists, skipping: $junctionPath" -ForegroundColor Yellow
        } else {
            $actualDesc = if ($existing.LinkType -eq 'Junction') { $existingTarget } else { "(not a junction)" }
            Write-Warning "Path exists but is not the expected junction: $junctionPath`n  Expected target: $targetPath`n  Actual:          $actualDesc"
            $hadErrors = $true
        }
        continue
    }

    try {
        New-Item -ItemType Junction -Path $junctionPath -Target $targetPath -ErrorAction Stop | Out-Null
        Write-Host "Created: $junctionPath -> $targetPath" -ForegroundColor Green
    } catch {
        Write-Error "ERROR creating junction $junctionPath -> $targetPath : $_"
        $hadErrors = $true
    }
}

if ($hadErrors) { exit 1 }
