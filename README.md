# Work Metrics

Local productivity dashboard for your GitHub user and local Git repositories. It does not require a server: it generates a self-contained HTML file that can be opened directly in the browser.

## Usage

```powershell
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -OpenReport
```

The generated dashboard is static. Switching periods in the UI uses data already embedded in `out/dashboard.html`; it does not call GitHub or start a server.

Useful options:

```powershell
# Change embedded periods
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -Periods "30,90,180,365"

# Query GitHub again instead of using the local cache
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -Periods "30,90,180,365" -Refresh

# Change the repository root
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -Root C:\source\repos

# Force a GitHub user
powershell -ExecutionPolicy Bypass -File .\build-dashboard.ps1 -User octocat

# Generate a single-period report
powershell -ExecutionPolicy Bypass -File .\work-metrics.ps1 -Days 30 -OpenReport
```

## Output

- `out/dashboard.html`: self-contained dashboard.
- `out/work-metrics.md`: latest generated Markdown report.
- `out/work-metrics.json`: latest generated raw data.
- `out/cache/metrics-{days}.json`: cached raw data per period, reused by default.

The `out/` directory contains real user data and is ignored by Git.

## Metrics

- Detected local repositories.
- Local commits in the selected period.
- Added lines, deleted lines, and changed files from `git log --numstat`.
- Meaningful lines, support lines, migration lines, and mechanical/bulk lines.
- Active days, first/last local commit, and busiest day.
- Daily, weekly, and monthly evolution.
- Longest active-day streak, active weeks, and consistency.
- Peak hour, work-hours percentage, out-of-hours commits, and weekend commits.
- Authored, reviewed, and involved pull requests from GitHub Search.
- Merged pull requests, median time to merge, and percentage merged under 24 hours.
- Authored, closed, and involved issues from GitHub Search.
- Threads commented by the user.

## Limitations

GitHub does not expose actual time worked. Time-related metrics are approximations based on observable activity, such as active days and commit windows. Line counts can include generated files when repositories commit them.

The dashboard keeps total activity and classified activity side by side. EF-style migrations are treated as support work, not discarded. Generated/vendor/build/lockfile changes are classified as mechanical. Large low-density changes are flagged as bulk, but still remain visible in the totals.

Team metrics, rankings, and scores are not calculated because they require uniform access to all repositories and all users. This tool intentionally focuses on personal metrics to avoid incomplete or biased comparisons.

## Security

The scripts do not store tokens or credentials. They use `gh` and the locally authenticated session.

Do not commit `out/`: it can include user names, local paths, repository names, PR/issue URLs and titles, commits, and author emails. For publishing the tool, track only source files such as `work-metrics.ps1`, `build-dashboard.ps1`, `public/`, `README.md`, and `.gitignore`.
