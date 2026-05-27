const state = { data: null, loading: false };
const embeddedData = window.__WORK_METRICS_DATA__ || {};
const fmt = new Intl.NumberFormat();

const form = document.getElementById("periodForm");
const daysSelect = document.getElementById("days");
const statusEl = document.getElementById("status");
const includePartial = document.getElementById("includePartial");

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

includePartial.addEventListener("change", () => {
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
    const scope = includePartial.checked ? "including current week" : "excluding the current partial week";
    setStatus(`Showing ${days} days, ${scope}. To update the source data, run build-dashboard.ps1 again.`);
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
  const monthlyRows = filterLeadingPartialMonth(report.Monthly, summary.Since);
  const weeklyRows = filterPeriods(report.Weekly, "week", summary.GeneratedAt);
  document.getElementById("subtitle").textContent = `${summary.User} · ${summary.Since.slice(0, 10)} to ${summary.GeneratedAt.slice(0, 10)} · ${summary.Days} days`;

  renderSummary(summary);
  renderTrend(weeklyRows, monthlyRows);
  renderReconciliation(report);
  drawChart(document.getElementById("monthlyChart"), monthlyRows, "Period");
  drawChart(document.getElementById("weeklyChart"), weeklyRows, "Period");
  renderRepoTable(report.Repositories);
  renderTable("monthlyTable", monthlyRows);
  renderTable("weeklyTable", weeklyRows);
}

function filterPeriods(rows, type, generatedAt) {
  if (includePartial.checked || type !== "week") return rows;
  const generatedDate = new Date(`${generatedAt.slice(0, 10)}T00:00:00`);
  return rows.filter(row => {
    const start = new Date(`${row.Period}T00:00:00`);
    const end = new Date(start);
    end.setDate(start.getDate() + 7);
    return generatedDate >= end;
  });
}

function filterLeadingPartialMonth(rows, since) {
  if (!rows.length) return rows;
  const sinceDate = new Date(`${since.slice(0, 10)}T00:00:00`);
  if (sinceDate.getDate() === 1) return rows;
  const partialPeriod = `${sinceDate.getFullYear()}-${String(sinceDate.getMonth() + 1).padStart(2, "0")}`;
  return rows.filter(row => row.Period !== partialPeriod);
}

function renderSummary(summary) {
  const metrics = [
    ["Meaningful lines", summary.MeaningfulLines],
    ["Outside meaningful", `${valueOrFallback(summary.OutsideMeaningfulLines)} support/mechanical`],
    ["Support lines", `${valueOrFallback(summary.SupportLines)} incl. ${valueOrFallback(summary.MigrationLines)} migrations`],
    ["Mechanical/bulk", `${valueOrFallback(summary.MechanicalOrBulkLines)} (${valueOrFallback(summary.MechanicalRatioPercent)}%)`],
    ["Commits", summary.Commits],
    ["PRs", `${summary.PullRequestsAuthored} created / ${summary.PullRequestsMerged} merged`],
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
    const css = deltaClass(row.MeaningfulLinesDelta);
    return `<div class="trend-card">
      <div class="label">${label}</div>
      <div class="period">${row.Period}</div>
      <div class="value">${fmt.format(row.MeaningfulLines || 0)} meaningful lines</div>
      <div class="delta ${css}">${formatDelta(row.MeaningfulLinesDelta)} vs previous (${formatPercent(row.MeaningfulLinesPercent)})</div>
    </div>`;
  }).join("");
}

function sumRows(rows, key) {
  return rows.reduce((total, row) => total + Number(row[key] || 0), 0);
}

function renderReconciliation(report) {
  const rows = [
    ["Summary", report.Summary.MeaningfulLines, report.Summary.SupportLines, report.Summary.MechanicalOrBulkLines, report.Summary.Commits],
    ["Monthly detail", sumRows(report.Monthly, "MeaningfulLines"), sumRows(report.Monthly, "SupportLines"), sumRows(report.Monthly, "MechanicalOrBulkLines"), sumRows(report.Monthly, "Commits")],
    ["Weekly detail", sumRows(report.Weekly, "MeaningfulLines"), sumRows(report.Weekly, "SupportLines"), sumRows(report.Weekly, "MechanicalOrBulkLines"), sumRows(report.Weekly, "Commits")],
    ["Repository participation", sumRows(report.Repositories, "MeaningfulLines"), sumRows(report.Repositories, "SupportLines"), sumRows(report.Repositories, "MechanicalOrBulkLines"), sumRows(report.Repositories, "Commits")]
  ];

  document.getElementById("reconciliation").innerHTML = `<table>
    <thead><tr><th>Source</th><th class="num">Meaningful</th><th class="num">Support</th><th class="num">Mechanical/bulk</th><th class="num">Commits</th></tr></thead>
    <tbody>${rows.map(row => `<tr>
      <td>${row[0]}</td>
      <td class="num">${fmt.format(row[1] || 0)}</td>
      <td class="num">${fmt.format(row[2] || 0)}</td>
      <td class="num">${fmt.format(row[3] || 0)}</td>
      <td class="num">${fmt.format(row[4] || 0)}</td>
    </tr>`).join("")}</tbody>
  </table>
  <p class="note">Line metrics are calculated from authored commits across fetched Git refs. PR counts come from GitHub Search and are shown separately.</p>`;
}

function renderTable(id, rows) {
  document.getElementById(id).innerHTML = `<table>
    <thead><tr><th>Period</th><th class="num">Meaningful</th><th class="num">Meaningful evolution</th><th class="num">Support</th><th class="num">Migrations</th><th class="num">Mechanical/bulk</th><th class="num">Commits</th></tr></thead>
    <tbody>${rows.map(row => `<tr>
      <td>${row.Period}</td>
      <td class="num">${fmt.format(row.MeaningfulLines || 0)}</td>
      <td class="num ${deltaClass(row.MeaningfulLinesDelta)}">${formatDelta(row.MeaningfulLinesDelta)} (${formatPercent(row.MeaningfulLinesPercent)})</td>
      <td class="num">${fmt.format(row.SupportLines || 0)}</td>
      <td class="num">${fmt.format(row.MigrationLines || 0)}</td>
      <td class="num">${fmt.format(row.MechanicalOrBulkLines || 0)}</td>
      <td class="num">${fmt.format(row.Commits || 0)}</td>
    </tr>`).join("")}</tbody>
  </table>`;
}

function renderRepoTable(repositories) {
  const sortedRows = [...repositories]
    .sort((a, b) => (b.MeaningfulLines || 0) - (a.MeaningfulLines || 0))
  const visibleRows = sortedRows.slice(0, 12);
  const hiddenRows = sortedRows.slice(12);
  const rows = [...visibleRows];

  if (hiddenRows.length > 0) {
    rows.push({
      Repo: `Other repositories (${hiddenRows.length})`,
      MeaningfulLines: sumRows(hiddenRows, "MeaningfulLines"),
      SupportLines: sumRows(hiddenRows, "SupportLines"),
      MigrationLines: sumRows(hiddenRows, "MigrationLines"),
      MechanicalOrBulkLines: sumRows(hiddenRows, "MechanicalOrBulkLines"),
      Commits: sumRows(hiddenRows, "Commits")
    });
  }

  rows.push({
    Repo: "Total",
    MeaningfulLines: sumRows(sortedRows, "MeaningfulLines"),
    SupportLines: sumRows(sortedRows, "SupportLines"),
    MigrationLines: sumRows(sortedRows, "MigrationLines"),
    MechanicalOrBulkLines: sumRows(sortedRows, "MechanicalOrBulkLines"),
    Commits: sumRows(sortedRows, "Commits")
  });

  document.getElementById("repoTable").innerHTML = `<table>
    <thead><tr><th>Repository</th><th class="num">Meaningful</th><th class="num">Support</th><th class="num">Migrations</th><th class="num">Mechanical/bulk</th><th class="num">Commits</th></tr></thead>
    <tbody>${rows.map(row => `<tr class="${row.Repo === "Total" ? "total-row" : ""}">
      <td>${row.Repo}</td>
      <td class="num">${fmt.format(row.MeaningfulLines || 0)}</td>
      <td class="num">${fmt.format(row.SupportLines || 0)}</td>
      <td class="num">${fmt.format(row.MigrationLines || 0)}</td>
      <td class="num">${fmt.format(row.MechanicalOrBulkLines || 0)}</td>
      <td class="num">${fmt.format(row.Commits || 0)}</td>
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
  const values = rows.map(row => Number(row.MeaningfulLines || 0));
  const maxValue = Math.max(1, ...values);
  const minValue = Math.min(...values);
  const range = Math.max(1, maxValue - minValue);
  const yMin = minValue > 0 ? Math.max(0, minValue - range * 0.15) : 0;
  const yMax = maxValue + range * 0.10;
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
    ctx.fillText(fmt.format(Math.round(yMin + ((yMax - yMin) * i / 4))), 8, y + 4);
  }

  ctx.strokeStyle = "#2563eb";
  ctx.lineWidth = 2.5;
  ctx.beginPath();
  rows.forEach((row, index) => {
    const x = pad.left + (rows.length > 1 ? step * index : width / 2);
    const y = pad.top + height - (((Number(row.MeaningfulLines || 0) - yMin) / (yMax - yMin)) * height);
    if (index === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  });
  ctx.stroke();

  ctx.fillStyle = "#111827";
  ctx.font = "12px Segoe UI, Arial";
  rows.forEach((row, index) => {
    const x = pad.left + (rows.length > 1 ? step * index : width / 2);
    const y = pad.top + height - (((Number(row.MeaningfulLines || 0) - yMin) / (yMax - yMin)) * height);
    ctx.beginPath();
    ctx.arc(x, y, 3, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillText(fmt.format(row.MeaningfulLines || 0), x + 6, Math.max(14, y - 8));
  });

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
