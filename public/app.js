const state = { data: null, loading: false };
const embeddedData = window.__WORK_METRICS_DATA__ || {};
const fmt = new Intl.NumberFormat();

const form = document.getElementById("periodForm");
const daysSelect = document.getElementById("days");
const statusEl = document.getElementById("status");

function readStoredPeriod() {
  try {
    return localStorage.getItem("workMetrics.period");
  }
  catch {
    return null;
  }
}

function writeStoredPeriod(period) {
  try {
    localStorage.setItem("workMetrics.period", String(period));
  }
  catch {
    // Some browsers block localStorage for file:// pages.
  }
}

function readUrlPeriod() {
  try {
    return new URLSearchParams(window.location.search).get("days");
  }
  catch {
    return null;
  }
}

function writeUrlPeriod(period) {
  try {
    const url = new URL(window.location.href);
    url.searchParams.set("days", String(period));
    history.replaceState(null, "", url);
  }
  catch {
    // file:// history updates can be restricted in some browsers.
  }
}

const urlPeriod = readUrlPeriod();
const savedPeriod = urlPeriod || readStoredPeriod();
if (savedPeriod && embeddedData[savedPeriod]) {
  daysSelect.value = savedPeriod;
}
else {
  const availablePeriods = Object.keys(embeddedData).sort((a, b) => Number(a) - Number(b));
  if (availablePeriods.length > 0 && !embeddedData[daysSelect.value]) {
    daysSelect.value = availablePeriods[Math.min(1, availablePeriods.length - 1)];
  }
}

form.addEventListener("submit", event => {
  event.preventDefault();
  renderSelectedPeriod();
});

daysSelect.addEventListener("change", () => {
  renderSelectedPeriod();
});

function setStatus(text) {
  statusEl.textContent = text;
}

function renderPeriod(days) {
  try {
    const data = embeddedData[String(days)];
  if (!data) {
      const available = Object.keys(embeddedData).sort((a, b) => Number(a) - Number(b)).join(", ");
      setStatus(`No data embedded for ${days} days. Available: ${available || "none"}. Run build-dashboard.ps1 to add it.`);
    return;
  }
  state.data = data;
    writeStoredPeriod(days);
    writeUrlPeriod(days);
  render(data);
  setStatus(`Showing ${days} days. To update the source data, run build-dashboard.ps1 again.`);
  }
  catch (error) {
    setStatus(`Could not render ${days} days: ${error.message}`);
  }
}

function renderSelectedPeriod() {
  setStatus(`Loading ${daysSelect.value} days...`);
  window.requestAnimationFrame(() => renderPeriod(daysSelect.value));
}

function valueOrFallback(value, suffix = "") {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  if (typeof value === "number") return fmt.format(value) + suffix;
  return String(value) + suffix;
}

function formatPercent(value) {
  if (value === null || value === undefined || Number.isNaN(value)) return "n/a";
  const sign = value > 0 ? "+" : "";
  return `${sign}${value.toFixed(1)}%`;
}

function formatDelta(value) {
  if (value === null || value === undefined || Number.isNaN(value)) return "first period";
  const sign = value > 0 ? "+" : "";
  return `${sign}${fmt.format(value)}`;
}

function deltaClass(value) {
  if (value === null || value === undefined || Number.isNaN(value) || value === 0) return "flat";
  return value > 0 ? "up" : "down";
}

function render(report) {
  const summary = report.Summary;
  document.getElementById("subtitle").textContent = `${summary.User} · ${summary.Since.slice(0, 10)} to ${summary.GeneratedAt.slice(0, 10)} · ${summary.Days} days`;

  renderSummary(summary);
  renderTrend(report.Weekly, report.Monthly);
  drawChart(document.getElementById("monthlyChart"), report.Monthly, "Period");
  drawChart(document.getElementById("weeklyChart"), report.Weekly, "Period");
  renderTable("monthlyTable", report.Monthly);
  renderTable("weeklyTable", report.Weekly);
}

function renderSummary(summary) {
  const metrics = [
    ["Changed lines", (summary.Additions || 0) + (summary.Deletions || 0)],
    ["Commits", summary.Commits],
    ["PRs", `${summary.PullRequestsAuthored} created / ${summary.PullRequestsMerged} merged`],
    ["Reviews", summary.PullRequestsReviewed],
    ["Active days", `${summary.ActiveCommitDays} / streak ${summary.MaxActiveDayStreak}`],
    ["Merge speed", `${valueOrFallback(summary.PullRequestMedianMergeHours)}h median`]
  ];

  document.getElementById("summary").innerHTML = metrics.map(([label, value]) =>
    `<div class="metric"><div class="label">${label}</div><div class="value">${valueOrFallback(value)}</div></div>`
  ).join("");
}

function renderTrend(weekly, monthly) {
  const cards = [
    ["Latest week", weekly?.at(-1)],
    ["Latest month", monthly?.at(-1)]
  ].filter(([, row]) => row);

  document.getElementById("trend").innerHTML = cards.map(([label, row]) => {
    const css = deltaClass(row.LinesChangedDelta);
    return `<div class="trend-card">
      <div class="label">${label}</div>
      <div class="period">${row.Period}</div>
      <div class="value">${fmt.format(row.LinesChanged || 0)} changed lines</div>
      <div class="delta ${css}">${formatDelta(row.LinesChangedDelta)} vs previous (${formatPercent(row.LinesChangedPercent)})</div>
    </div>`;
  }).join("");
}

function renderTable(id, rows) {
  document.getElementById(id).innerHTML = `<table>
    <thead><tr><th>Period</th><th class="num">Changed lines</th><th class="num">Evolution</th><th class="num">Commits</th><th class="num">PR files</th></tr></thead>
    <tbody>${rows.map(row => `<tr>
      <td>${row.Period}</td>
      <td class="num">${fmt.format(row.LinesChanged || 0)}</td>
      <td class="num ${deltaClass(row.LinesChangedDelta)}">${formatDelta(row.LinesChangedDelta)} (${formatPercent(row.LinesChangedPercent)})</td>
      <td class="num">${fmt.format(row.Commits || 0)}</td>
      <td class="num">${fmt.format(row.Files || 0)}</td>
    </tr>`).join("")}</tbody>
  </table>`;
}

function drawChart(canvas, rows, labelKey) {
  const ctx = canvas.getContext("2d");
  const dpr = window.devicePixelRatio || 1;
  const rect = canvas.getBoundingClientRect();
  canvas.width = Math.max(1, Math.floor(rect.width * dpr));
  canvas.height = Math.max(1, Math.floor(rect.height * dpr));
  ctx.scale(dpr, dpr);
  ctx.clearRect(0, 0, rect.width, rect.height);

  const pad = { left: 58, right: 18, top: 18, bottom: 48 };
  const width = rect.width - pad.left - pad.right;
  const height = rect.height - pad.top - pad.bottom;
  const max = Math.max(1, ...rows.map(row => Number(row.LinesChanged || 0)));
  const step = rows.length > 1 ? width / (rows.length - 1) : width;

  ctx.font = "12px Segoe UI, Arial";
  ctx.strokeStyle = "#d9dee8";
  ctx.fillStyle = "#667085";
  for (let i = 0; i <= 4; i++) {
    const y = pad.top + height - (height * i / 4);
    ctx.beginPath();
    ctx.moveTo(pad.left, y);
    ctx.lineTo(pad.left + width, y);
    ctx.stroke();
    ctx.fillText(fmt.format(Math.round(max * i / 4)), 8, y + 4);
  }

  ctx.strokeStyle = "#2563eb";
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  rows.forEach((row, index) => {
    const x = pad.left + (rows.length > 1 ? step * index : width / 2);
    const y = pad.top + height - ((Number(row.LinesChanged || 0) / max) * height);
    if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();

  const labelEvery = Math.max(1, Math.ceil(rows.length / 8));
  rows.forEach((row, index) => {
    if (index % labelEvery !== 0 && index !== rows.length - 1) return;
    const x = pad.left + (rows.length > 1 ? step * index : width / 2);
    ctx.save();
    ctx.translate(x, pad.top + height + 18);
    ctx.rotate(-0.45);
    ctx.fillText(row[labelKey], 0, 0);
    ctx.restore();
  });
}

window.addEventListener("resize", () => {
  if (state.data) render(state.data);
});

try {
  renderSelectedPeriod();
}
catch (error) {
  setStatus(`Could not initialize dashboard: ${error.message}`);
}
