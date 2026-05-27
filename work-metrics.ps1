param(
    [int]$Days = 30,
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [string]$OutDir = (Join-Path $PSScriptRoot "out"),
    [string]$User = "",
    [string[]]$GitAuthorPatterns = @(),
    [switch]$OpenReport
)

$ErrorActionPreference = "Stop"

function Invoke-JsonCommand {
    param([string[]]$Command)

    $output = & $Command[0] $Command[1..($Command.Length - 1)] 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $($Command -join ' ')"
    }

    if ([string]::IsNullOrWhiteSpace($output)) {
        return $null
    }

    return ($output | ConvertFrom-Json)
}

function Invoke-GhSearch {
    param(
        [string]$Kind,
        [string]$Query,
        [int]$Limit = 200
    )

    $items = @()
    $page = 1
    $perPage = 100

    while ($items.Count -lt $Limit) {
        $remaining = [Math]::Min($perPage, $Limit - $items.Count)
        $result = Invoke-JsonCommand @("gh", "api", "-X", "GET", "search/$Kind", "-f", "q=$Query", "-f", "per_page=$remaining", "-f", "page=$page")
        if ($null -eq $result -or $null -eq $result.items -or $result.items.Count -eq 0) {
            break
        }

        $items += @($result.items)
        if ($result.items.Count -lt $remaining) {
            break
        }
        $page++
    }

    return $items
}

function Get-RepoSlug {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ""
    }

    if ($Url -match "github\.com[:/](?<owner>[^/]+)/(?<repo>[^#?]+?)(?:\.git)?$") {
        return "$($Matches.owner)/$($Matches.repo)"
    }

    return $Url
}

$script:CanonicalSlugCache = @{}

function Resolve-CanonicalRepoSlug {
    param(
        [string]$OriginSlug,
        [string]$UpstreamSlug
    )

    if (-not [string]::IsNullOrWhiteSpace($UpstreamSlug)) {
        return $UpstreamSlug
    }

    if ([string]::IsNullOrWhiteSpace($OriginSlug)) {
        return ""
    }

    if ($script:CanonicalSlugCache.ContainsKey($OriginSlug)) {
        return $script:CanonicalSlugCache[$OriginSlug]
    }

    $canonical = $OriginSlug
    try {
        $repoJson = & gh repo view $OriginSlug --json isFork,parent,nameWithOwner 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoJson)) {
            $repoInfo = $repoJson | ConvertFrom-Json
            if ($null -ne $repoInfo -and $repoInfo.isFork -eq $true -and $null -ne $repoInfo.parent -and -not [string]::IsNullOrWhiteSpace($repoInfo.parent.nameWithOwner)) {
                $canonical = $repoInfo.parent.nameWithOwner
            }
        }
    }
    catch {
        $canonical = $OriginSlug
    }

    $script:CanonicalSlugCache[$OriginSlug] = $canonical
    return $canonical
}

function Get-LocalRepos {
    param([string]$RootPath)

    Get-ChildItem -Path $RootPath -Directory -Force |
        Where-Object { Test-Path (Join-Path $_.FullName ".git") } |
        ForEach-Object {
            $origin = ""
            $upstream = ""
            Push-Location $_.FullName
            try {
                $remotes = @(& git remote)
                if ($remotes -contains "origin") {
                    $origin = (& git remote get-url origin)
                }
                if ($remotes -contains "upstream") {
                    $upstream = (& git remote get-url upstream)
                }
            }
            finally {
                Pop-Location
            }

            $originSlug = Get-RepoSlug $origin
            $upstreamSlug = Get-RepoSlug $upstream
            $canonicalSlug = Resolve-CanonicalRepoSlug $originSlug $upstreamSlug

            [pscustomobject]@{
                Name = $_.Name
                Path = $_.FullName
                Remote = $origin
                Slug = $canonicalSlug
            }
        }
}

function Get-ChangeCategory {
    param([string]$Path)

    $normalized = ($Path -replace "\\", "/").ToLowerInvariant()
    $fileName = ($normalized -split "/")[-1]
    $extension = if ($fileName -match "(\.[^.]+)$") { $Matches[1] } else { "" }

    if ($normalized -match "(^|/)(bin|obj|dist|build|node_modules|packages|vendor|coverage|generated|swagger|openapi)(/|$)" -or
        $fileName -match "\.(g|generated|designer)\." -or
        $fileName -match "\.min\." -or
        $fileName -in @("package-lock.json", "pnpm-lock.yaml", "yarn.lock", "composer.lock", "poetry.lock")) {
        return "Mechanical"
    }

    if ($normalized -match "(^|/)(migrations)(/|$)" -or
        $fileName -match "^\d{12,}_.+\.(cs|sql)$" -or
        $fileName -match "model(snapshot)?\.cs$") {
        return "Migration"
    }

    if ($normalized -match "(^|/)(test|tests|__tests__)(/|$)" -or
        $fileName -match "(test|tests|spec)\.(cs|ts|tsx|js|jsx)$") {
        return "Tests"
    }

    if ($extension -in @(".md", ".txt", ".adoc", ".rst")) {
        return "Docs"
    }

    if ($extension -in @(".json", ".yml", ".yaml", ".xml", ".props", ".targets", ".config", ".editorconfig", ".sln", ".csproj", ".fsproj", ".vbproj")) {
        return "Config"
    }

    if ($extension -in @(".cs", ".fs", ".vb", ".ts", ".tsx", ".js", ".jsx", ".razor", ".sql", ".ps1", ".sh", ".css", ".scss", ".html")) {
        return "Core"
    }

    return "Other"
}

function Complete-CommitMetrics {
    param([object]$Commit)

    if ($null -eq $Commit) {
        return
    }

    $commitLines = [int]$Commit.Additions + [int]$Commit.Deletions
    $meaningfulLines = [int]$Commit.CoreLines + [int]$Commit.TestLines
    $supportLines = [int]$Commit.MigrationLines + [int]$Commit.ConfigLines + [int]$Commit.DocLines
    $mechanicalLines = [int]$Commit.MechanicalLines
    $bulkLines = 0

    if ($Commit.Files -ge 50 -and $Commit.Files -gt 0 -and ($commitLines / $Commit.Files) -le 8) {
        $bulkLines = $commitLines
    }

    $Commit | Add-Member -NotePropertyName MeaningfulLines -NotePropertyValue $meaningfulLines -Force
    $Commit | Add-Member -NotePropertyName SupportLines -NotePropertyValue $supportLines -Force
    $Commit | Add-Member -NotePropertyName BulkLines -NotePropertyValue $bulkLines -Force
    $Commit | Add-Member -NotePropertyName MechanicalOrBulkLines -NotePropertyValue ($mechanicalLines + $bulkLines) -Force
}

function Get-CommitStats {
    param(
        [object]$Repo,
        [DateTime]$Since,
        [string[]]$AuthorPatterns
    )

    $commits = @()
    Push-Location $Repo.Path
    try {
        & git fetch --all --prune --quiet 2>$null
        foreach ($author in $AuthorPatterns) {
            $log = & git log --all "--since=$($Since.ToString("yyyy-MM-ddTHH:mm:sszzz"))" "--author=$author" --date=iso-strict --numstat --pretty=format:"--COMMIT--%H|%ad|%an|%ae|%s" 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($log)) {
                continue
            }

            $current = $null
            foreach ($line in $log) {
                if ($line.StartsWith("--COMMIT--")) {
                    if ($null -ne $current) {
                        Complete-CommitMetrics $current
                        $commits += $current
                    }
                    $parts = $line.Substring(10).Split("|", 5)
                    $current = [pscustomobject]@{
                        Repo = $Repo.Name
                        Slug = $Repo.Slug
                        Sha = $parts[0]
                        DateTime = $parts[1]
                        Date = ([datetimeoffset]::Parse($parts[1])).Date.ToString("yyyy-MM-dd")
                        Hour = ([datetimeoffset]::Parse($parts[1])).Hour
                        IsWeekend = @([DayOfWeek]::Saturday, [DayOfWeek]::Sunday) -contains ([datetimeoffset]::Parse($parts[1])).DayOfWeek
                        IsWorkHours = (([datetimeoffset]::Parse($parts[1])).Hour -ge 7 -and ([datetimeoffset]::Parse($parts[1])).Hour -lt 20 -and -not (@([DayOfWeek]::Saturday, [DayOfWeek]::Sunday) -contains ([datetimeoffset]::Parse($parts[1])).DayOfWeek))
                        AuthorName = $parts[2]
                        AuthorEmail = $parts[3]
                        Subject = $parts[4]
                        Additions = 0
                        Deletions = 0
                        Files = 0
                        CoreLines = 0
                        TestLines = 0
                        MigrationLines = 0
                        ConfigLines = 0
                        DocLines = 0
                        MechanicalLines = 0
                        OtherLines = 0
                    }
                    continue
                }

                if ($null -eq $current -or [string]::IsNullOrWhiteSpace($line)) {
                    continue
                }

                $cols = $line -split "\t"
                if ($cols.Count -ge 3 -and $cols[0] -match "^\d+$" -and $cols[1] -match "^\d+$") {
                    $added = [int]$cols[0]
                    $deleted = [int]$cols[1]
                    $changed = $added + $deleted
                    $category = Get-ChangeCategory $cols[2]
                    $current.Additions += $added
                    $current.Deletions += $deleted
                    $current.Files++
                    switch ($category) {
                        "Core" { $current.CoreLines += $changed }
                        "Tests" { $current.TestLines += $changed }
                        "Migration" { $current.MigrationLines += $changed }
                        "Config" { $current.ConfigLines += $changed }
                        "Docs" { $current.DocLines += $changed }
                        "Mechanical" { $current.MechanicalLines += $changed }
                        default { $current.OtherLines += $changed }
                    }
                }
            }

            if ($null -ne $current) {
                Complete-CommitMetrics $current
                $commits += $current
            }
        }
    }
    finally {
        Pop-Location
    }

    return $commits | Sort-Object Sha -Unique
}

function Write-MetricTable {
    param(
        [System.Text.StringBuilder]$Builder,
        [string]$Title,
        [object[]]$Rows,
        [string[]]$Columns
    )

    [void]$Builder.AppendLine("## $Title")
    [void]$Builder.AppendLine()

    if ($Rows.Count -eq 0) {
        [void]$Builder.AppendLine("_Sin datos para este periodo._")
        [void]$Builder.AppendLine()
        return
    }

    [void]$Builder.AppendLine("| $($Columns -join " | ") |")
    [void]$Builder.AppendLine("| $($Columns.ForEach({ "---" }) -join " | ") |")
    foreach ($row in $Rows) {
        $values = foreach ($column in $Columns) {
            $value = $row.$column
            if ($null -eq $value) { "" } else { ($value.ToString() -replace "\|", "\|") }
        }
        [void]$Builder.AppendLine("| $($values -join " | ") |")
    }
    [void]$Builder.AppendLine()
}

function Get-WeekStart {
    param([DateTime]$Date)

    $offset = ([int]$Date.DayOfWeek + 6) % 7
    return $Date.Date.AddDays(-1 * $offset)
}

function Get-PeriodStats {
    param(
        [object[]]$Rows,
        [scriptblock]$KeySelector,
        [scriptblock]$LabelSelector
    )

    @(
        $Rows |
            Group-Object { & $KeySelector $_ } |
            ForEach-Object {
                $first = $_.Group | Select-Object -First 1
                [pscustomobject]@{
                    Period = & $LabelSelector $first
                    Commits = $_.Count
                    Additions = ($_.Group | Measure-Object Additions -Sum).Sum
                    Deletions = ($_.Group | Measure-Object Deletions -Sum).Sum
                    Files = ($_.Group | Measure-Object Files -Sum).Sum
                    MeaningfulLines = ($_.Group | Measure-Object MeaningfulLines -Sum).Sum
                    SupportLines = ($_.Group | Measure-Object SupportLines -Sum).Sum
                    MigrationLines = ($_.Group | Measure-Object MigrationLines -Sum).Sum
                    MechanicalOrBulkLines = ($_.Group | Measure-Object MechanicalOrBulkLines -Sum).Sum
                    ActiveDays = @(($_.Group | Select-Object -ExpandProperty Date -Unique)).Count
                }
            } |
            Sort-Object Period
    )
}

function Add-TrendStats {
    param([object[]]$Rows)

    $previous = $null
    foreach ($row in $Rows) {
        $linesChanged = [int]$row.Additions + [int]$row.Deletions
        $previousLinesChanged = if ($null -eq $previous) { $null } else { [int]$previous.Additions + [int]$previous.Deletions }
        $delta = if ($null -eq $previousLinesChanged) { $null } else { $linesChanged - $previousLinesChanged }
        $changePercent = if ($null -eq $previousLinesChanged -or $previousLinesChanged -eq 0) { $null } else { [Math]::Round(($delta / $previousLinesChanged) * 100, 1) }
        $meaningfulDelta = if ($null -eq $previous) { $null } else { [int]$row.MeaningfulLines - [int]$previous.MeaningfulLines }
        $meaningfulPercent = if ($null -eq $previous -or [int]$previous.MeaningfulLines -eq 0) { $null } else { [Math]::Round(($meaningfulDelta / [int]$previous.MeaningfulLines) * 100, 1) }

        $row | Add-Member -NotePropertyName LinesChanged -NotePropertyValue $linesChanged -Force
        $row | Add-Member -NotePropertyName PreviousLinesChanged -NotePropertyValue $previousLinesChanged -Force
        $row | Add-Member -NotePropertyName LinesChangedDelta -NotePropertyValue $delta -Force
        $row | Add-Member -NotePropertyName LinesChangedPercent -NotePropertyValue $changePercent -Force
        $row | Add-Member -NotePropertyName MeaningfulLinesDelta -NotePropertyValue $meaningfulDelta -Force
        $row | Add-Member -NotePropertyName MeaningfulLinesPercent -NotePropertyValue $meaningfulPercent -Force

        $previous = $row
    }

    return $Rows
}

function Get-MaxDateStreak {
    param([string[]]$Dates)

    $orderedDates = @($Dates | Sort-Object -Unique | ForEach-Object { [datetime]::Parse($_) })
    if ($orderedDates.Count -eq 0) {
        return 0
    }

    $max = 1
    $current = 1
    for ($i = 1; $i -lt $orderedDates.Count; $i++) {
        if (($orderedDates[$i] - $orderedDates[$i - 1]).Days -eq 1) {
            $current++
            $max = [Math]::Max($max, $current)
        }
        else {
            $current = 1
        }
    }

    return $max
}

function Get-Median {
    param([double[]]$Values)

    $ordered = @($Values | Sort-Object)
    if ($ordered.Count -eq 0) {
        return $null
    }

    $middle = [Math]::Floor($ordered.Count / 2)
    if ($ordered.Count % 2 -eq 1) {
        return [Math]::Round($ordered[$middle], 1)
    }

    return [Math]::Round((($ordered[$middle - 1] + $ordered[$middle]) / 2), 1)
}

function ConvertTo-HtmlJson {
    param([object]$Value)

    return ($Value | ConvertTo-Json -Depth 8).Replace("</", "<\/")
}

function Write-Utf8NoBom {
    param(
        [string]$Path,
        [string]$Content
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Write-HtmlReport {
    param(
        [string]$Path,
        [object]$Report
    )

    $summaryJson = ConvertTo-HtmlJson $Report.Summary
    $dailyJson = ConvertTo-HtmlJson $Report.Daily
    $weeklyJson = ConvertTo-HtmlJson $Report.Weekly
    $monthlyJson = ConvertTo-HtmlJson $Report.Monthly
    $repoJson = ConvertTo-HtmlJson $Report.Repositories

    $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Work metrics</title>
  <style>
    :root { color-scheme: light; --text:#202124; --muted:#5f6368; --line:#dadce0; --panel:#ffffff; --bg:#f8fafd; --blue:#1a73e8; --green:#188038; --red:#d93025; --amber:#f29900; }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: Segoe UI, Roboto, Arial, sans-serif; color: var(--text); background: var(--bg); }
    header { padding: 28px 32px 18px; background: #fff; border-bottom: 1px solid var(--line); }
    h1 { margin: 0 0 8px; font-size: 28px; font-weight: 650; letter-spacing: 0; }
    h2 { margin: 0 0 14px; font-size: 18px; font-weight: 650; letter-spacing: 0; }
    main { padding: 24px 32px 40px; display: grid; gap: 20px; }
    .muted { color: var(--muted); }
    .trend-summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 12px; }
    .trend-card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 16px; }
    .trend-card .label { color: var(--muted); font-size: 12px; margin-bottom: 8px; }
    .trend-card .period { font-size: 18px; font-weight: 650; margin-bottom: 10px; }
    .trend-card .value { font-size: 24px; font-weight: 750; margin-bottom: 4px; }
    .trend-card .delta { font-size: 14px; font-weight: 600; }
    .up { color: var(--green); }
    .down { color: var(--red); }
    .flat { color: var(--muted); }
    .metrics { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 12px; }
    .metric, .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; }
    .metric { padding: 14px 16px; min-height: 84px; }
    .metric .label { color: var(--muted); font-size: 12px; margin-bottom: 8px; }
    .metric .value { font-size: 26px; font-weight: 700; }
    .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(360px, 1fr)); gap: 20px; }
    .panel { padding: 18px; min-width: 0; }
    canvas { width: 100%; height: 280px; display: block; }
    table { width: 100%; border-collapse: collapse; font-size: 13px; }
    th, td { padding: 9px 8px; border-bottom: 1px solid var(--line); text-align: left; }
    th { color: var(--muted); font-weight: 600; }
    td.num, th.num { text-align: right; }
    @media (max-width: 720px) {
      header, main { padding-left: 16px; padding-right: 16px; }
      .grid { grid-template-columns: 1fr; }
      canvas { height: 240px; }
    }
  </style>
</head>
<body>
  <header>
    <h1>Work metrics for @$($Report.Summary.User)</h1>
    <div class="muted">$($Report.Summary.Since.Substring(0, 10)) to $($Report.Summary.GeneratedAt.Substring(0, 10)) &middot; $($Report.Summary.Days) days</div>
  </header>
  <main>
    <section class="metrics" id="metrics"></section>
    <section class="trend-summary" id="trendSummary"></section>
    <section class="grid">
      <div class="panel"><h2>Weekly line changes</h2><canvas id="weekly"></canvas></div>
      <div class="panel"><h2>Monthly line changes</h2><canvas id="monthly"></canvas></div>
      <div class="panel"><h2>Daily commits</h2><canvas id="daily"></canvas></div>
      <div class="panel"><h2>Repository impact</h2><canvas id="repos"></canvas></div>
    </section>
    <section class="panel">
      <h2>Weekly detail</h2>
      <div id="weeklyTable"></div>
    </section>
    <section class="panel">
      <h2>Monthly detail</h2>
      <div id="monthlyTable"></div>
    </section>
  </main>
  <script>
    const summary = $summaryJson;
    const daily = $dailyJson;
    const weekly = $weeklyJson;
    const monthly = $monthlyJson;
    const repos = $repoJson;

    const fmt = new Intl.NumberFormat();
    const metricDefs = [
      ["Commits", summary.Commits],
      ["Lines added", summary.Additions],
      ["Lines deleted", summary.Deletions],
      ["Files changed", summary.FilesChanged],
      ["Active days", summary.ActiveCommitDays],
      ["Max streak", summary.MaxActiveDayStreak],
      ["Consistency", (summary.ConsistencyPercent || 0) + "%"],
      ["Peak hour", summary.PeakCommitHour || "n/a"],
      ["Authored PRs", summary.PullRequestsAuthored],
      ["Merged PRs", summary.PullRequestsMerged],
      ["Reviewed PRs", summary.PullRequestsReviewed],
      ["Median merge", (summary.PullRequestMedianMergeHours ?? "n/a") + "h"],
      ["PRs < 24h", (summary.PullRequestsMergedUnder24Hours || 0) + "%"],
      ["Issues involved", summary.IssuesInvolved],
      ["Issues closed", summary.IssuesClosedInvolved],
      ["Commented threads", summary.CommentedThreads],
      ["Work hours", (summary.WorkHoursCommitPercent || 0) + "%"],
      ["Out of hours", summary.OutsideWorkHoursCommits],
      ["Weekend commits", summary.WeekendCommits]
    ];
    document.getElementById("metrics").innerHTML = metricDefs.map(([label, value]) =>
      '<div class="metric"><div class="label">' + label + '</div><div class="value">' + fmt.format(value || 0) + '</div></div>'
    ).join("");

    function formatPercent(value) {
      if (value === null || value === undefined) return "n/a";
      const sign = value > 0 ? "+" : "";
      return sign + value.toFixed(1) + "%";
    }

    function formatDelta(value) {
      if (value === null || value === undefined) return "first period";
      const sign = value > 0 ? "+" : "";
      return sign + fmt.format(value);
    }

    function deltaClass(value) {
      if (value === null || value === undefined || value === 0) return "flat";
      return value > 0 ? "up" : "down";
    }

    function renderTrendSummary() {
      const lastWeek = weekly[weekly.length - 1];
      const lastMonth = monthly[monthly.length - 1];
      const cards = [
        ["Latest week", lastWeek],
        ["Latest month", lastMonth]
      ].filter(item => item[1]);
      document.getElementById("trendSummary").innerHTML = cards.map(([label, row]) => {
        const pct = formatPercent(row.LinesChangedPercent);
        const delta = formatDelta(row.LinesChangedDelta);
        const css = deltaClass(row.LinesChangedDelta);
        return '<div class="trend-card"><div class="label">' + label + '</div><div class="period">' + row.Period + '</div><div class="value">' + fmt.format(row.LinesChanged || 0) + ' changed lines</div><div class="delta ' + css + '">' + delta + ' vs previous (' + pct + ')</div></div>';
      }).join("");
    }

    function drawChart(canvas, rows, labelKey, series) {
      const ctx = canvas.getContext("2d");
      const dpr = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      canvas.width = Math.max(1, Math.floor(rect.width * dpr));
      canvas.height = Math.max(1, Math.floor(rect.height * dpr));
      ctx.scale(dpr, dpr);
      ctx.clearRect(0, 0, rect.width, rect.height);

      const pad = { left: 52, right: 18, top: 16, bottom: 44 };
      const width = rect.width - pad.left - pad.right;
      const height = rect.height - pad.top - pad.bottom;
      const max = Math.max(1, ...rows.flatMap(row => series.map(s => Number(row[s.key] || 0))));
      const step = rows.length > 1 ? width / (rows.length - 1) : width;

      ctx.strokeStyle = "#dadce0";
      ctx.lineWidth = 1;
      ctx.font = "12px Segoe UI, Arial";
      ctx.fillStyle = "#5f6368";
      for (let i = 0; i <= 4; i++) {
        const y = pad.top + height - (height * i / 4);
        ctx.beginPath();
        ctx.moveTo(pad.left, y);
        ctx.lineTo(pad.left + width, y);
        ctx.stroke();
        ctx.fillText(fmt.format(Math.round(max * i / 4)), 8, y + 4);
      }

      series.forEach(s => {
        ctx.strokeStyle = s.color;
        ctx.lineWidth = 2;
        ctx.beginPath();
        rows.forEach((row, index) => {
          const x = pad.left + (rows.length > 1 ? step * index : width / 2);
          const y = pad.top + height - ((Number(row[s.key] || 0) / max) * height);
          if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        });
        ctx.stroke();
      });

      const labelEvery = Math.max(1, Math.ceil(rows.length / 8));
      ctx.fillStyle = "#5f6368";
      rows.forEach((row, index) => {
        if (index % labelEvery !== 0 && index !== rows.length - 1) return;
        const x = pad.left + (rows.length > 1 ? step * index : width / 2);
        ctx.save();
        ctx.translate(x, pad.top + height + 16);
        ctx.rotate(-0.45);
        ctx.fillText(row[labelKey], 0, 0);
        ctx.restore();
      });

      let legendX = pad.left;
      series.forEach(s => {
        ctx.fillStyle = s.color;
        ctx.fillRect(legendX, 4, 10, 10);
        ctx.fillStyle = "#5f6368";
        ctx.fillText(s.label, legendX + 14, 13);
        legendX += 96;
      });
    }

    function drawBarChart(canvas, rows) {
      const ctx = canvas.getContext("2d");
      const dpr = window.devicePixelRatio || 1;
      const rect = canvas.getBoundingClientRect();
      canvas.width = Math.max(1, Math.floor(rect.width * dpr));
      canvas.height = Math.max(1, Math.floor(rect.height * dpr));
      ctx.scale(dpr, dpr);
      const topRows = [...rows].sort((a, b) => b.Additions - a.Additions).slice(0, 10).reverse();
      const pad = { left: 118, right: 18, top: 12, bottom: 20 };
      const width = rect.width - pad.left - pad.right;
      const rowHeight = (rect.height - pad.top - pad.bottom) / Math.max(1, topRows.length);
      const max = Math.max(1, ...topRows.map(row => Number(row.Additions || 0)));
      ctx.clearRect(0, 0, rect.width, rect.height);
      ctx.font = "12px Segoe UI, Arial";
      topRows.forEach((row, index) => {
        const y = pad.top + index * rowHeight + 5;
        const barWidth = width * Number(row.Additions || 0) / max;
        ctx.fillStyle = "#5f6368";
        ctx.fillText(String(row.Repo).slice(0, 18), 6, y + rowHeight * 0.55);
        ctx.fillStyle = "#1a73e8";
        ctx.fillRect(pad.left, y, barWidth, Math.max(8, rowHeight - 12));
        ctx.fillStyle = "#202124";
        ctx.fillText(fmt.format(row.Additions || 0), pad.left + barWidth + 6, y + rowHeight * 0.55);
      });
    }

    function renderTable(id, rows) {
      document.getElementById(id).innerHTML = '<table><thead><tr><th>Period</th><th class="num">Changed lines</th><th class="num">Evolution</th><th class="num">Commits</th><th class="num">Added</th><th class="num">Deleted</th><th class="num">Files</th><th class="num">Active days</th></tr></thead><tbody>' +
        rows.map(row => '<tr><td>' + row.Period + '</td><td class="num">' + fmt.format(row.LinesChanged || 0) + '</td><td class="num ' + deltaClass(row.LinesChangedDelta) + '">' + formatDelta(row.LinesChangedDelta) + ' (' + formatPercent(row.LinesChangedPercent) + ')</td><td class="num">' + fmt.format(row.Commits || 0) + '</td><td class="num">' + fmt.format(row.Additions || 0) + '</td><td class="num">' + fmt.format(row.Deletions || 0) + '</td><td class="num">' + fmt.format(row.Files || 0) + '</td><td class="num">' + fmt.format(row.ActiveDays || 0) + '</td></tr>').join("") +
        "</tbody></table>";
    }

    function renderAll() {
      const lineChangeSeries = [
        { key: "Additions", label: "Added", color: "#1a73e8" },
        { key: "Deletions", label: "Deleted", color: "#d93025" }
      ];
      drawChart(document.getElementById("weekly"), weekly, "Period", lineChangeSeries);
      drawChart(document.getElementById("monthly"), monthly, "Period", lineChangeSeries);
      drawChart(document.getElementById("daily"), daily, "Date", [{ key: "Commits", label: "Commits", color: "#1a73e8" }]);
      drawBarChart(document.getElementById("repos"), repos);
      renderTrendSummary();
      renderTable("weeklyTable", weekly);
      renderTable("monthlyTable", monthly);
    }
    window.addEventListener("resize", renderAll);
    renderAll();
  </script>
</body>
</html>
"@

    Write-Utf8NoBom $Path $html
}

if ([string]::IsNullOrWhiteSpace($User)) {
    $User = (& gh api user --jq ".login").Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($User)) {
        throw "Could not resolve GitHub user. Run gh auth login first or pass -User."
    }
}

if ($GitAuthorPatterns.Count -eq 0) {
    $profile = Invoke-JsonCommand @("gh", "api", "user")
    $GitAuthorPatterns = @($User)
    if (-not [string]::IsNullOrWhiteSpace($profile.name)) {
        $GitAuthorPatterns += $profile.name
    }
    if (-not [string]::IsNullOrWhiteSpace($profile.email)) {
        $GitAuthorPatterns += $profile.email
    }
}

$since = (Get-Date).AddDays(-1 * $Days)
$sinceIso = $since.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$sinceDate = $since.ToString("yyyy-MM-dd")
$now = Get-Date

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$repos = @(Get-LocalRepos $Root)
$commits = @()
foreach ($repo in $repos) {
    $commits += @(Get-CommitStats $repo $since $GitAuthorPatterns)
}
$commits = @($commits | Sort-Object Slug, Sha -Unique)

$prsAuthored = @(Invoke-GhSearch "issues" "type:pr author:$User updated:>=$sinceDate" 300)
$prsMentioned = @(Invoke-GhSearch "issues" "type:pr involves:$User -author:$User updated:>=$sinceDate" 300)
$prsMerged = @(Invoke-GhSearch "issues" "type:pr author:$User merged:>=$sinceDate" 300)
$issuesAuthored = @(Invoke-GhSearch "issues" "type:issue author:$User updated:>=$sinceDate" 300)
$issuesInvolved = @(Invoke-GhSearch "issues" "type:issue involves:$User -author:$User updated:>=$sinceDate" 300)
$issuesClosedAuthored = @(Invoke-GhSearch "issues" "type:issue author:$User closed:>=$sinceDate" 300)
$issuesClosedInvolved = @(Invoke-GhSearch "issues" "type:issue involves:$User closed:>=$sinceDate" 300)
$commentedThreads = @(Invoke-GhSearch "issues" "commenter:$User updated:>=$sinceDate" 300)
$reviews = @(Invoke-GhSearch "issues" "type:pr reviewed-by:$User updated:>=$sinceDate" 300)

$repoStats = @(
    $commits |
        Group-Object Slug |
        ForEach-Object {
            [pscustomobject]@{
                Repo = $_.Name
                Commits = $_.Count
                Additions = ($_.Group | Measure-Object Additions -Sum).Sum
                Deletions = ($_.Group | Measure-Object Deletions -Sum).Sum
                Files = ($_.Group | Measure-Object Files -Sum).Sum
                MeaningfulLines = ($_.Group | Measure-Object MeaningfulLines -Sum).Sum
                SupportLines = ($_.Group | Measure-Object SupportLines -Sum).Sum
                MigrationLines = ($_.Group | Measure-Object MigrationLines -Sum).Sum
                MechanicalOrBulkLines = ($_.Group | Measure-Object MechanicalOrBulkLines -Sum).Sum
            }
        } |
        Sort-Object Commits, Additions -Descending
)

$dailyStats = @(
    $commits |
        Group-Object Date |
        ForEach-Object {
            [pscustomobject]@{
                Date = $_.Name
                Commits = $_.Count
                Additions = ($_.Group | Measure-Object Additions -Sum).Sum
                Deletions = ($_.Group | Measure-Object Deletions -Sum).Sum
                Files = ($_.Group | Measure-Object Files -Sum).Sum
                MeaningfulLines = ($_.Group | Measure-Object MeaningfulLines -Sum).Sum
                SupportLines = ($_.Group | Measure-Object SupportLines -Sum).Sum
                MigrationLines = ($_.Group | Measure-Object MigrationLines -Sum).Sum
                MechanicalOrBulkLines = ($_.Group | Measure-Object MechanicalOrBulkLines -Sum).Sum
            }
        } |
        Sort-Object Date
)

$weeklyStats = Get-PeriodStats $commits `
    { param($row) (Get-WeekStart ([datetime]::Parse($row.Date))).ToString("yyyy-MM-dd") } `
    { param($row) (Get-WeekStart ([datetime]::Parse($row.Date))).ToString("yyyy-MM-dd") }
$weeklyStats = Add-TrendStats $weeklyStats

$monthlyStats = Get-PeriodStats $commits `
    { param($row) ([datetime]::Parse($row.Date)).ToString("yyyy-MM") } `
    { param($row) ([datetime]::Parse($row.Date)).ToString("yyyy-MM") }
$monthlyStats = Add-TrendStats $monthlyStats

$commitDates = @($commits | ForEach-Object { [datetime]::Parse($_.Date) } | Sort-Object)
$firstCommitDate = if ($commitDates.Count -gt 0) { $commitDates[0].ToString("yyyy-MM-dd") } else { "" }
$lastCommitDate = if ($commitDates.Count -gt 0) { $commitDates[-1].ToString("yyyy-MM-dd") } else { "" }
$activeDays = @($dailyStats | Where-Object { $_.Commits -gt 0 }).Count
$busiestDay = @($dailyStats | Sort-Object Commits, Additions -Descending | Select-Object -First 1)
$periodWeeks = @($weeklyStats).Count
$activeWeeks = @($weeklyStats | Where-Object { $_.Commits -gt 0 }).Count
$consistencyPercent = if ($periodWeeks -gt 0) { [Math]::Round(($activeWeeks / $periodWeeks) * 100, 0) } else { 0 }
$maxStreak = Get-MaxDateStreak @($dailyStats | Select-Object -ExpandProperty Date)
$peakHourGroup = @($commits | Group-Object Hour | Sort-Object Count -Descending | Select-Object -First 1)
$peakHour = if ($peakHourGroup.Count -gt 0) { "{0:00}:00" -f [int]$peakHourGroup[0].Name } else { "" }
$workHoursCommits = @($commits | Where-Object { $_.IsWorkHours }).Count
$outsideWorkHoursCommits = @($commits | Where-Object { -not $_.IsWorkHours -and -not $_.IsWeekend }).Count
$weekendCommits = @($commits | Where-Object { $_.IsWeekend }).Count
$workHoursPercent = if ($commits.Count -gt 0) { [Math]::Round(($workHoursCommits / $commits.Count) * 100, 0) } else { 0 }
$mergedPrDurations = @(
    $prsMerged |
        Where-Object { $null -ne $_.pull_request -and -not [string]::IsNullOrWhiteSpace($_.pull_request.merged_at) } |
        ForEach-Object { (([datetime]::Parse($_.pull_request.merged_at)) - ([datetime]::Parse($_.created_at))).TotalHours }
)
$medianMergeHours = Get-Median $mergedPrDurations
$prsMergedUnder24Hours = @($mergedPrDurations | Where-Object { $_ -lt 24 }).Count
$prsMergedUnder24Percent = if ($mergedPrDurations.Count -gt 0) { [Math]::Round(($prsMergedUnder24Hours / $mergedPrDurations.Count) * 100, 0) } else { 0 }

$topPrs = @(
    $prsAuthored |
        Sort-Object updated_at -Descending |
        Select-Object -First 20 @{Name="Repo";Expression={$_.repository_url.Split("/")[-2..-1] -join "/"}}, number, title, state, html_url
)

$topIssues = @(
    ($issuesAuthored + $issuesInvolved) |
        Sort-Object updated_at -Descending -Unique |
        Select-Object -First 20 @{Name="Repo";Expression={$_.repository_url.Split("/")[-2..-1] -join "/"}}, number, title, state, html_url
)

$summary = [pscustomobject]@{
    GeneratedAt = $now.ToString("s")
    User = $User
    Days = $Days
    Since = $since.ToString("s")
    Root = $Root
    LocalRepositories = $repos.Count
    Commits = $commits.Count
    Additions = ($commits | Measure-Object Additions -Sum).Sum
    Deletions = ($commits | Measure-Object Deletions -Sum).Sum
    FilesChanged = ($commits | Measure-Object Files -Sum).Sum
    MeaningfulLines = ($commits | Measure-Object MeaningfulLines -Sum).Sum
    SupportLines = ($commits | Measure-Object SupportLines -Sum).Sum
    MigrationLines = ($commits | Measure-Object MigrationLines -Sum).Sum
    MechanicalOrBulkLines = ($commits | Measure-Object MechanicalOrBulkLines -Sum).Sum
    OutsideMeaningfulLines = (($commits | Measure-Object SupportLines -Sum).Sum + ($commits | Measure-Object MechanicalOrBulkLines -Sum).Sum)
    MechanicalRatioPercent = if ((($commits | Measure-Object Additions -Sum).Sum + ($commits | Measure-Object Deletions -Sum).Sum) -gt 0) { [Math]::Round(((($commits | Measure-Object MechanicalOrBulkLines -Sum).Sum) / ((($commits | Measure-Object Additions -Sum).Sum + ($commits | Measure-Object Deletions -Sum).Sum)) * 100), 1) } else { 0 }
    ActiveCommitDays = $activeDays
    MaxActiveDayStreak = $maxStreak
    ActiveWeeks = "$activeWeeks/$periodWeeks"
    ConsistencyPercent = $consistencyPercent
    PeakCommitHour = $peakHour
    WorkHoursCommitPercent = $workHoursPercent
    OutsideWorkHoursCommits = $outsideWorkHoursCommits
    WeekendCommits = $weekendCommits
    FirstLocalCommitDate = $firstCommitDate
    LastLocalCommitDate = $lastCommitDate
    BusiestLocalCommitDay = if ($busiestDay.Count -gt 0) { "$($busiestDay[0].Date) ($($busiestDay[0].Commits) commits)" } else { "" }
    PullRequestsAuthored = $prsAuthored.Count
    PullRequestsMerged = $prsMerged.Count
    PullRequestsReviewed = $reviews.Count
    PullRequestsInvolved = $prsMentioned.Count
    PullRequestMedianMergeHours = $medianMergeHours
    PullRequestsMergedUnder24Hours = $prsMergedUnder24Percent
    IssuesAuthored = $issuesAuthored.Count
    IssuesInvolved = $issuesInvolved.Count
    IssuesClosedAuthored = $issuesClosedAuthored.Count
    IssuesClosedInvolved = $issuesClosedInvolved.Count
    CommentedThreads = $commentedThreads.Count
}

$json = [pscustomobject]@{
    Summary = $summary
    Repositories = $repoStats
    Daily = $dailyStats
    Weekly = $weeklyStats
    Monthly = $monthlyStats
    PullRequestsAuthored = $topPrs
    Issues = $topIssues
    Commits = $commits | Sort-Object Date -Descending
}

$jsonPath = Join-Path $OutDir "work-metrics.json"
$mdPath = Join-Path $OutDir "work-metrics.md"
$htmlPath = Join-Path $OutDir "work-metrics.html"
Write-Utf8NoBom $jsonPath ($json | ConvertTo-Json -Depth 8)

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("# Work metrics for @$User")
[void]$md.AppendLine()
[void]$md.AppendLine("Period: $($since.ToString("yyyy-MM-dd")) to $($now.ToString("yyyy-MM-dd")) ($Days days)")
[void]$md.AppendLine()
[void]$md.AppendLine("## Summary")
[void]$md.AppendLine()
[void]$md.AppendLine("| Metric | Value |")
[void]$md.AppendLine("| --- | ---: |")
foreach ($property in $summary.PSObject.Properties) {
    [void]$md.AppendLine("| $($property.Name) | $($property.Value) |")
}
[void]$md.AppendLine()

Write-MetricTable $md "Local Git Activity By Repository" $repoStats @("Repo", "Commits", "Additions", "Deletions", "Files", "MeaningfulLines", "SupportLines", "MigrationLines", "MechanicalOrBulkLines")
Write-MetricTable $md "Local Git Activity By Week" $weeklyStats @("Period", "LinesChanged", "LinesChangedDelta", "LinesChangedPercent", "Commits", "MeaningfulLines", "SupportLines", "MigrationLines", "MechanicalOrBulkLines", "Files", "ActiveDays")
Write-MetricTable $md "Local Git Activity By Month" $monthlyStats @("Period", "LinesChanged", "LinesChangedDelta", "LinesChangedPercent", "Commits", "MeaningfulLines", "SupportLines", "MigrationLines", "MechanicalOrBulkLines", "Files", "ActiveDays")
Write-MetricTable $md "Local Git Activity By Day" $dailyStats @("Date", "Commits", "Additions", "Deletions", "Files", "MeaningfulLines", "SupportLines", "MigrationLines", "MechanicalOrBulkLines")
Write-MetricTable $md "Recent Authored PRs" $topPrs @("Repo", "number", "title", "state", "html_url")
Write-MetricTable $md "Recent Issues Authored/Involved" $topIssues @("Repo", "number", "title", "state", "html_url")

Write-Utf8NoBom $mdPath $md.ToString()
Write-HtmlReport $htmlPath $json

Write-Host "Markdown: $mdPath"
Write-Host "JSON:     $jsonPath"
Write-Host "HTML:     $htmlPath"
Write-Host ""
Write-Host "Summary"
$summary | Format-List

if ($OpenReport) {
    Start-Process $htmlPath
}
