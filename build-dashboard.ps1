param(
    [string]$Periods = "30,90,180,365",
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$OutDir = (Join-Path $PSScriptRoot "out"),
    [string]$User = "",
    [switch]$OpenReport
)

$ErrorActionPreference = "Stop"

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function ConvertTo-HtmlJson {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 20).Replace("</", "<\/")
}

$periodValues = @(
    $Periods -split "," |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match "^\d+$" } |
        ForEach-Object { [int]$_ } |
        Where-Object { $_ -ge 7 -and $_ -le 730 } |
        Sort-Object -Unique
)

if ($periodValues.Count -eq 0) {
    throw "No valid periods supplied. Example: -Periods ""30,90,180,365"""
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$dashboardData = [ordered]@{}
foreach ($period in $periodValues) {
    Write-Host "Generating $period days..."
    $args = @("-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "work-metrics.ps1"), "-Days", $period, "-Root", $Root, "-OutDir", $OutDir)
    if (-not [string]::IsNullOrWhiteSpace($User)) {
        $args += @("-User", $User)
    }

    & powershell @args | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate metrics for $period days."
    }

    $jsonPath = Join-Path $OutDir "work-metrics.json"
    $dashboardData["$period"] = Get-Content -Path $jsonPath -Raw | ConvertFrom-Json

    if ($period -ne $periodValues[-1]) {
        Start-Sleep -Seconds 5
    }
}

$index = Get-Content -Path (Join-Path $PSScriptRoot "public\index.html") -Raw
$styles = Get-Content -Path (Join-Path $PSScriptRoot "public\styles.css") -Raw
$app = Get-Content -Path (Join-Path $PSScriptRoot "public\app.js") -Raw
$dataJson = ConvertTo-HtmlJson $dashboardData

$html = $index.
    Replace('<link rel="stylesheet" href="styles.css">', "<style>`n$styles`n</style>").
    Replace('<script src="app.js"></script>', "<script>window.__WORK_METRICS_DATA__ = $dataJson;</script>`n<script>`n$app`n</script>")

$dashboardPath = Join-Path $OutDir "dashboard.html"
Write-Utf8NoBom $dashboardPath $html

Write-Host "Dashboard: $dashboardPath"
if ($OpenReport) {
    Start-Process $dashboardPath
}
