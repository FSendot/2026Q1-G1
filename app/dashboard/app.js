(function () {
  "use strict";

  const DEMO_USER    = "cloud";
  const DEMO_PASS    = "cloud";
  const SESSION_KEY  = "fd_session_v2";
  const AUTO_REFRESH = 60_000;

  // ── State ──────────────────────────────────────────────────────────────────
  let refreshTimer = null;

  // Global filters — shared across all tabs
  let gf = { user_id: "", country: "", channel: "", from: "", to: "" };

  // Per-tab state (not affected by global filters)
  let txState    = { offset: 0, limit: 20, is_fraud: null, sortBy: "processed_at", sortDir: "desc" };
  let usersState = { offset: 0, limit: 20, sortBy: "fraud_count", sortDir: "desc" };

  // ── DOM helpers ────────────────────────────────────────────────────────────
  const $ = id => document.getElementById(id);
  const qsa = sel => document.querySelectorAll(sel);

  // ── Tooltip ────────────────────────────────────────────────────────────────
  const TIP = {
    el: null,
    show(e, html) {
      if (!this.el) this.el = $("tip");
      this.el.innerHTML = html;
      this.el.hidden = false;
      this._pos(e);
    },
    move(e) { if (this.el && !this.el.hidden) this._pos(e); },
    hide()   { if (this.el) this.el.hidden = true; },
    _pos(e) {
      const el = this.el;
      const W = window.innerWidth;
      // Temporarily make visible to measure
      el.style.visibility = "hidden"; el.hidden = false;
      const w = el.offsetWidth, h = el.offsetHeight;
      el.style.visibility = "";
      let x = e.clientX - w / 2;
      let y = e.clientY - h - 10;
      if (y < 6)      y = e.clientY + 18; // flip below cursor
      if (x < 6)      x = 6;
      if (x + w > W)  x = W - w - 6;
      el.style.left = x + "px";
      el.style.top  = y + "px";
    },
  };

  // ── Sortable table headers ─────────────────────────────────────────────────
  function initSortHeaders(tableId, state, loadFn) {
    document.querySelectorAll(`#${tableId} th[data-sort]`).forEach(th => {
      th.addEventListener("click", () => {
        const col = th.dataset.sort;
        if (state.sortBy === col) {
          state.sortDir = state.sortDir === "desc" ? "asc" : "desc";
        } else {
          state.sortBy  = col;
          state.sortDir = "desc";
        }
        state.offset = 0;
        updateSortHeaders(tableId, state);
        loadFn();
      });
    });
    updateSortHeaders(tableId, state);
  }

  function updateSortHeaders(tableId, state) {
    document.querySelectorAll(`#${tableId} th[data-sort]`).forEach(th => {
      const col  = th.dataset.sort;
      const icon = th.querySelector(".sort-icon");
      const active = col === state.sortBy;
      th.classList.toggle("sort-active", active);
      if (icon) icon.textContent = active
        ? (state.sortDir === "asc" ? " ↑" : " ↓")
        : " ⇅";
    });
  }

  function attachSvgTooltips(svgEl) {
    if (!svgEl) return;
    svgEl.addEventListener("mousemove", e => {
      const t = e.target.closest("[data-tip]");
      if (t) TIP.show(e, t.dataset.tip);
      else   TIP.hide();
    });
    svgEl.addEventListener("mouseleave", () => TIP.hide());
  }

  function esc(s) {
    return String(s == null ? "—" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  function fmt(n)  { return n != null ? Number(n).toLocaleString("es-AR") : "—"; }
  function fmtPct(n) { return n != null ? (parseFloat(n) * 100).toFixed(1) + "%" : "—"; }
  function fmtDate(iso) {
    if (!iso) return "—";
    try { return new Date(iso).toLocaleString("es-AR", { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit" }); }
    catch (_) { return iso; }
  }
  function fmtAmount(n, cur) {
    if (n == null) return "—";
    return new Intl.NumberFormat("es-AR", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n) + (cur ? " " + cur : "");
  }
  function decisionPill(d) {
    const key = String(d || "").toLowerCase();
    const map = { allow: ["allow", "Permitida"], block: ["block", "Bloqueada"], challenge: ["challenge", "Challenge"] };
    const [cls, label] = map[key] || ["", d || "—"];
    return `<span class="pill ${cls}">${esc(label)}</span>`;
  }
  function kpiCard(value, label, variant) {
    return `<div class="kpi-card${variant ? " " + variant : ""}"><div class="kpi-value">${esc(String(value))}</div><div class="kpi-label">${esc(label)}</div></div>`;
  }

  // ── API ────────────────────────────────────────────────────────────────────
  const apiBase = () => (window.API_BASE || "").replace(/\/$/, "");

  async function apiFetch(path) {
    const res = await fetch(apiBase() + path, { headers: { Accept: "application/json" } });
    if (!res.ok) {
      const body = await res.json().catch(() => ({}));
      throw new Error(body?.error?.message || "HTTP " + res.status);
    }
    return res.json();
  }

  function gfParams(extra) {
    const p = new URLSearchParams();
    if (gf.user_id) p.set("user_id", gf.user_id);
    if (gf.country) p.set("country", gf.country);
    if (gf.channel) p.set("channel", gf.channel);
    if (gf.from)    p.set("from", gf.from);
    if (gf.to)      p.set("to", gf.to);
    if (extra) Object.entries(extra).forEach(([k, v]) => v != null && p.set(k, v));
    return p;
  }

  function hasActiveFilters() {
    return Object.values(gf).some(v => v !== "");
  }

  // ── Auth ───────────────────────────────────────────────────────────────────
  const isAuthed = () => sessionStorage.getItem(SESSION_KEY) === "1";

  function doLogout() {
    sessionStorage.removeItem(SESSION_KEY);
    clearInterval(refreshTimer);
    showView("login");
  }

  // ── Views ──────────────────────────────────────────────────────────────────
  function showView(name) {
    $("view-login").hidden = name !== "login";
    $("view-app").hidden   = name !== "app";
    if (name === "app") {
      loadFiltersDropdowns();
      setTab("overview");
    }
  }

  // ── Global filters ─────────────────────────────────────────────────────────
  async function loadFiltersDropdowns() {
    try {
      const res = await apiFetch("/filters");
      const { countries = [], channels = [] } = res.data || {};
      populateSelect("gf-country", countries, "País: todos");
      populateSelect("gf-channel", channels,  "Canal: todos");
    } catch (_) { /* non-fatal */ }
  }

  function populateSelect(id, values, placeholder) {
    const sel = $(id);
    const current = sel.value;
    sel.innerHTML = `<option value="">${esc(placeholder)}</option>` +
      values.map(v => `<option value="${esc(v)}"${v === current ? " selected" : ""}>${esc(v)}</option>`).join("");
  }

  function applyGlobalFilters() {
    gf = {
      user_id: $("gf-user").value.trim(),
      country: $("gf-country").value,
      channel: $("gf-channel").value,
      from:    $("gf-from").value,
      to:      $("gf-to").value,
    };
    $("active-badge").hidden = !hasActiveFilters();
    txState.offset    = 0;
    usersState.offset = 0;
    const active = document.querySelector(".tab-btn.active");
    if (active) setTab(active.dataset.tab);
  }

  function clearGlobalFilters() {
    gf = { user_id: "", country: "", channel: "", from: "", to: "" };
    $("gf-user").value    = "";
    $("gf-country").value = "";
    $("gf-channel").value = "";
    $("gf-from").value    = "";
    $("gf-to").value      = "";
    $("active-badge").hidden = true;
    txState.offset    = 0;
    usersState.offset = 0;
    const active = document.querySelector(".tab-btn.active");
    if (active) setTab(active.dataset.tab);
  }

  // ── Tabs ───────────────────────────────────────────────────────────────────
  function setTab(tab) {
    qsa(".tab-btn").forEach(b => b.classList.toggle("active", b.dataset.tab === tab));
    qsa(".tab-pane").forEach(p => p.classList.toggle("active", p.id === "tab-" + tab));
    clearInterval(refreshTimer);

    if (tab === "overview") {
      loadOverview();
      refreshTimer = setInterval(loadOverview, AUTO_REFRESH);
    } else if (tab === "transactions") {
      loadTransactions();
    } else if (tab === "users") {
      loadUsers();
    }
  }

  // ── Status ─────────────────────────────────────────────────────────────────
  function setStatus(s) {
    $("status-dot").className = "dot " + s;
    $("status-text").textContent = { online: "En línea", offline: "Sin conexión", loading: "Verificando…" }[s] || s;
  }
  function showErr(tab, msg) { const e = $("error-" + tab); if (e) { e.textContent = msg; e.hidden = false; } }
  function clearErr(tab)     { const e = $("error-" + tab); if (e) { e.textContent = ""; e.hidden = true; } }

  // ── Overview ───────────────────────────────────────────────────────────────
  async function loadOverview() {
    setStatus("loading");
    clearErr("overview");
    try {
      const h = await apiFetch("/health");
      setStatus(h?.data?.status === "ok" ? "online" : "offline");
    } catch (e) {
      setStatus("offline");
      showErr("overview", "No se pudo contactar la API: " + e.message);
      return;
    }

    const p = gfParams();
    const hourlyP  = new URLSearchParams(p); hourlyP.set("granularity", "hour"); hourlyP.set("days", "1");
    const weeklyP  = new URLSearchParams(p); weeklyP.set("granularity", "day");  weeklyP.set("days", "7");

    const [statsR, tsR, weekR, fraudR] = await Promise.allSettled([
      apiFetch("/stats?" + p),
      apiFetch("/stats/timeseries?" + hourlyP),
      apiFetch("/stats/timeseries?" + weeklyP),
      apiFetch("/transactions?" + gfParams({ is_fraud: "true", limit: 10 })),
    ]);

    if (statsR.status === "fulfilled") {
      renderKpis(statsR.value.data);
      renderPie(statsR.value.data);
    }
    if (tsR.status   === "fulfilled") renderHourlyChart(tsR.value.data);
    if (weekR.status === "fulfilled") renderWeeklyChart(weekR.value.data);
    if (fraudR.status === "fulfilled") renderRecentFraud(fraudR.value.data);
  }

  function renderKpis(stats) {
    if (!stats) return;
    const rate = stats.fraud_rate != null ? (stats.fraud_rate * 100).toFixed(1) + "%" : "—";
    const avg  = stats.avg_fraud_score != null ? (stats.avg_fraud_score * 100).toFixed(1) + "%" : "—";
    $("kpi-grid").innerHTML = [
      kpiCard(fmt(stats.total),   "Procesadas",     ""),
      kpiCard(fmt(stats.fraud),   "Fraudes",        stats.fraud > 0 ? "danger" : ""),
      kpiCard(rate,               "Tasa fraude",    stats.fraud_rate > 0.05 ? "danger" : ""),
      kpiCard(avg,                "Score promedio", ""),
      kpiCard(fmt(stats.allowed), "Permitidas",     "success"),
      kpiCard(fmt(stats.blocked), "Bloqueadas",     ""),
    ].join("");
  }

  // ── Pie / donut chart ──────────────────────────────────────────────────────
  function polarToCart(cx, cy, r, deg) {
    const rad = deg * Math.PI / 180;
    return { x: cx + r * Math.cos(rad), y: cy + r * Math.sin(rad) };
  }

  function donutArc(cx, cy, outerR, innerR, startDeg, endDeg) {
    const span = endDeg - startDeg;
    if (span >= 359.9) {
      const mid = startDeg + 180;
      const a = polarToCart(cx, cy, outerR, startDeg), b = polarToCart(cx, cy, outerR, mid),
            c = polarToCart(cx, cy, outerR, endDeg),
            d = polarToCart(cx, cy, innerR, startDeg), e = polarToCart(cx, cy, innerR, mid),
            f = polarToCart(cx, cy, innerR, endDeg);
      return `M${a.x} ${a.y} A${outerR} ${outerR} 0 0 1 ${b.x} ${b.y} A${outerR} ${outerR} 0 0 1 ${c.x} ${c.y} L${f.x} ${f.y} A${innerR} ${innerR} 0 0 0 ${e.x} ${e.y} A${innerR} ${innerR} 0 0 0 ${d.x} ${d.y}Z`;
    }
    const large = span > 180 ? 1 : 0;
    const s1 = polarToCart(cx, cy, outerR, startDeg), e1 = polarToCart(cx, cy, outerR, endDeg),
          s2 = polarToCart(cx, cy, innerR, endDeg),   e2 = polarToCart(cx, cy, innerR, startDeg);
    return `M${s1.x.toFixed(2)} ${s1.y.toFixed(2)} A${outerR} ${outerR} 0 ${large} 1 ${e1.x.toFixed(2)} ${e1.y.toFixed(2)} L${s2.x.toFixed(2)} ${s2.y.toFixed(2)} A${innerR} ${innerR} 0 ${large} 0 ${e2.x.toFixed(2)} ${e2.y.toFixed(2)}Z`;
  }

  function renderPie(stats) {
    const wrap = $("pie-wrap");
    if (!stats || stats.total === 0) { wrap.innerHTML = '<p class="empty-msg">Sin datos.</p>'; return; }

    const segments = [
      { label: "Permitidas", count: stats.allowed    || 0, color: "#16a34a" },
      { label: "Bloqueadas", count: stats.blocked    || 0, color: "#dc2626" },
      { label: "Challenge",  count: stats.challenged || 0, color: "#d97706" },
    ].filter(s => s.count > 0);

    const total = segments.reduce((acc, s) => acc + s.count, 0);
    if (total === 0) { wrap.innerHTML = '<p class="empty-msg">Sin datos.</p>'; return; }

    const cx = 80, cy = 80, outerR = 68, innerR = 40;
    let paths = "", start = -90;

    segments.forEach(seg => {
      const span = (seg.count / total) * 360;
      const end  = start + span;
      const pct  = ((seg.count / total) * 100).toFixed(1);
      const tip  = `<b>${seg.label}</b><br>${fmt(seg.count)} transacciones · ${pct}%`;
      paths += `<path class="pie-seg" d="${donutArc(cx, cy, outerR, innerR, start, end)}" fill="${seg.color}" stroke="#fff" stroke-width="1.5" data-tip="${esc(tip)}"></path>`;
      start = end;
    });

    const legend = segments.map(s => {
      const pct = ((s.count / total) * 100).toFixed(1);
      return `<div class="pie-legend-item">
        <span class="pie-swatch" style="background:${s.color}"></span>
        <span class="pie-legend-label">${esc(s.label)}</span>
        <span class="pie-legend-count">${fmt(s.count)}</span>
        <span class="pie-legend-pct">${pct}%</span>
      </div>`;
    }).join("");

    wrap.innerHTML = `
      <svg id="pie-svg" viewBox="0 0 160 160" class="pie-svg">
        ${paths}
        <text x="${cx}" y="${cy - 7}" text-anchor="middle" fill="#6b7280" font-size="10" font-family="inherit">Total</text>
        <text x="${cx}" y="${cy + 11}" text-anchor="middle" fill="#111827" font-size="17" font-weight="700" font-family="inherit">${fmt(total)}</text>
      </svg>
      <div class="pie-legend">${legend}</div>`;

    attachSvgTooltips($("pie-svg"));
  }

  // ── Bar chart helpers ──────────────────────────────────────────────────────
  function _buildBarSvg(slots, labelFn, tickEvery) {
    const n = slots.length;
    const maxVal = Math.max(...slots.map(s => s.total), 1);
    const W = 560, H = 180, PL = 36, PR = 6, PT = 10, PB = 34;
    const cW = W - PL - PR, cH = H - PT - PB;
    const bW = Math.floor(cW / n), gap = Math.max(1, Math.floor(bW * 0.12));

    let grid = "", bars = "", labels = "";
    for (let i = 0; i <= 4; i++) {
      const y = PT + cH - (i / 4) * cH, val = Math.round(maxVal * i / 4);
      grid += `<line x1="${PL}" y1="${y.toFixed(1)}" x2="${W - PR}" y2="${y.toFixed(1)}" stroke="#e5e7eb" stroke-width="1"/>`;
      grid += `<text x="${PL - 4}" y="${(y + 4).toFixed(1)}" fill="#9ca3af" font-size="9" text-anchor="end" font-family="inherit">${val}</text>`;
    }
    slots.forEach((s, i) => {
      const x = PL + i * bW, by = PT + cH;
      const tH = s.total > 0 ? Math.max((s.total / maxVal) * cH, 2) : 0;
      const fH = s.fraud > 0 ? Math.max((s.fraud / maxVal) * cH, 2) : 0;
      const tip = `<b>${esc(labelFn(s))}</b><br>Total: ${s.total} · Fraudes: ${s.fraud}`;
      if (tH > 0) bars += `<rect class="bar-rect" x="${x + gap}" y="${(by - tH).toFixed(1)}" width="${bW - gap * 2}" height="${tH.toFixed(1)}" fill="#bfdbfe" rx="2" data-tip="${esc(tip)}"></rect>`;
      if (fH > 0) bars += `<rect class="bar-rect" x="${x + gap}" y="${(by - fH).toFixed(1)}" width="${bW - gap * 2}" height="${fH.toFixed(1)}" fill="#ef4444" opacity=".85" rx="2" data-tip="${esc(tip)}"></rect>`;
      if (i % tickEvery === 0) labels += `<text x="${(x + bW / 2).toFixed(1)}" y="${H - 5}" fill="#9ca3af" font-size="9" text-anchor="middle" font-family="inherit">${esc(labelFn(s, true))}</text>`;
    });

    return `${grid}${bars}${labels}`;
  }

  function _chartLegend() {
    return `<div class="chart-legend">
      <span class="legend-item"><i class="legend-swatch total"></i>Total</span>
      <span class="legend-item"><i class="legend-swatch fraud"></i>Fraudes</span>
    </div>`;
  }

  // ── Timeseries 24h ─────────────────────────────────────────────────────────
  function renderHourlyChart(data) {
    const wrap = $("chart-wrap");
    if (!data) { wrap.innerHTML = '<p class="empty-msg">Sin datos.</p>'; return; }

    const byHour = {};
    data.forEach(d => { try { byHour[new Date(d.hour).toISOString().slice(0, 13)] = d; } catch (_) {} });

    const slots = [];
    const base = new Date(); base.setMinutes(0, 0, 0);
    for (let i = 23; i >= 0; i--) {
      const h = new Date(base); h.setHours(h.getHours() - i);
      const d = byHour[h.toISOString().slice(0, 13)] || {};
      slots.push({ h, total: Number(d.total) || 0, fraud: Number(d.fraud) || 0 });
    }

    const labelFn = (s, short) => short
      ? String(s.h.getHours()).padStart(2, "0") + "h"
      : String(s.h.getHours()).padStart(2, "0") + ":00 UTC";

    const W = 560, H = 180;
    wrap.innerHTML = `
      <svg id="hourly-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet" class="chart-svg">
        ${_buildBarSvg(slots, labelFn, 4)}
      </svg>${_chartLegend()}`;
    attachSvgTooltips($("hourly-svg"));
  }

  // ── Timeseries 7 días ──────────────────────────────────────────────────────
  function renderWeeklyChart(data) {
    const wrap = $("chart-weekly-wrap");
    if (!data) { wrap.innerHTML = '<p class="empty-msg">Sin datos.</p>'; return; }

    const byDay = {};
    data.forEach(d => { try { byDay[new Date(d.hour).toISOString().slice(0, 10)] = d; } catch (_) {} });

    const DAY_NAMES = ["Dom", "Lun", "Mar", "Mié", "Jue", "Vie", "Sáb"];
    const slots = [];
    const base = new Date(); base.setHours(0, 0, 0, 0);
    for (let i = 6; i >= 0; i--) {
      const d = new Date(base); d.setDate(d.getDate() - i);
      const key = d.toISOString().slice(0, 10);
      const row = byDay[key] || {};
      slots.push({ d, key, total: Number(row.total) || 0, fraud: Number(row.fraud) || 0 });
    }

    const labelFn = (s, short) => short
      ? DAY_NAMES[s.d.getDay()] + " " + s.d.getDate()
      : DAY_NAMES[s.d.getDay()] + " " + s.d.getDate() + "/" + (s.d.getMonth() + 1);

    const W = 560, H = 180;
    wrap.innerHTML = `
      <svg id="weekly-svg" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMid meet" class="chart-svg">
        ${_buildBarSvg(slots, labelFn, 1)}
      </svg>${_chartLegend()}`;
    attachSvgTooltips($("weekly-svg"));
  }

  function renderRecentFraud(rows) {
    const tbody = document.querySelector("#recent-fraud-table tbody");
    if (!tbody) return;
    if (!rows || rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="7" class="empty-row">Sin transacciones fraudulentas recientes.</td></tr>';
      return;
    }
    tbody.innerHTML = rows.map(tx => `<tr>
      <td class="mono">${esc(tx.transaction_id)}</td>
      <td>${esc(tx.user_id)}</td>
      <td>${esc(fmtAmount(tx.amount, tx.currency))}</td>
      <td>${esc(tx.country)}</td>
      <td>${esc(tx.channel)}</td>
      <td>${esc(fmtPct(tx.fraud_score))}</td>
      <td>${esc(fmtDate(tx.processed_at))}</td>
    </tr>`).join("");
  }

  // ── Transactions ───────────────────────────────────────────────────────────
  async function loadTransactions() {
    clearErr("transactions");
    $("tx-tbody").innerHTML = '<tr><td colspan="8" class="loading-row">Cargando…</td></tr>';
    const extra = {
      limit:      txState.limit,
      offset:     txState.offset,
      sort_by:    txState.sortBy,
      sort_order: txState.sortDir,
    };
    if (txState.is_fraud === true)  extra.is_fraud = "true";
    if (txState.is_fraud === false) extra.is_fraud = "false";

    try {
      const res = await apiFetch("/transactions?" + gfParams(extra));
      renderTxTable(res.data, res.meta);
      updateSortHeaders("tx-table", txState);
    } catch (e) {
      showErr("transactions", e.message);
      $("tx-tbody").innerHTML = "";
    }
  }

  function renderTxTable(rows, meta) {
    const tbody = $("tx-tbody");
    if (!rows || rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="8" class="empty-row">Sin resultados para los filtros aplicados.</td></tr>';
    } else {
      tbody.innerHTML = rows.map(tx => `<tr>
        <td class="mono">${esc(tx.transaction_id)}</td>
        <td>${esc(tx.user_id)}</td>
        <td>${esc(fmtAmount(tx.amount, tx.currency))}</td>
        <td>${esc(tx.country)}</td>
        <td>${esc(tx.channel)}</td>
        <td>${esc(fmtPct(tx.fraud_score))}</td>
        <td>${decisionPill(tx.decision)}</td>
        <td>${esc(fmtDate(tx.processed_at))}</td>
      </tr>`).join("");
    }
    if (meta) {
      const page = Math.floor(meta.offset / meta.limit) + 1, pages = Math.ceil(meta.total / meta.limit) || 1;
      $("tx-page-info").textContent = `Página ${page} de ${pages} · ${fmt(meta.total)} resultados`;
      $("tx-prev").disabled = meta.offset === 0;
      $("tx-next").disabled = meta.offset + meta.limit >= meta.total;
    }
  }

  // ── Users ──────────────────────────────────────────────────────────────────
  async function loadUsers() {
    clearErr("users");
    $("users-tbody").innerHTML = '<tr><td colspan="6" class="loading-row">Cargando…</td></tr>';
    try {
      const res = await apiFetch("/users?" + gfParams({
        limit:      usersState.limit,
        offset:     usersState.offset,
        sort_by:    usersState.sortBy,
        sort_order: usersState.sortDir,
      }));
      renderUsersTable(res.data, res.meta);
      updateSortHeaders("users-table", usersState);
    } catch (e) {
      showErr("users", e.message);
      $("users-tbody").innerHTML = "";
    }
  }

  function renderUsersTable(rows, meta) {
    const tbody = $("users-tbody");
    if (!rows || rows.length === 0) {
      tbody.innerHTML = '<tr><td colspan="6" class="empty-row">Sin usuarios registrados.</td></tr>';
      return;
    }
    tbody.innerHTML = rows.map(u => {
      const rate = u.total_transactions > 0 ? ((u.fraud_count / u.total_transactions) * 100).toFixed(1) + "%" : "0%";
      return `<tr class="clickable" data-userid="${esc(u.user_id)}">
        <td class="mono">${esc(u.user_id)}</td>
        <td>${fmt(u.total_transactions)}</td>
        <td>${fmt(u.fraud_count)}</td>
        <td>${esc(rate)}</td>
        <td>${esc(fmtPct(u.avg_fraud_score))}</td>
        <td>${esc(fmtDate(u.last_seen))}</td>
      </tr>`;
    }).join("");
    tbody.querySelectorAll("tr.clickable").forEach(tr => {
      tr.addEventListener("click", () => openUserModal(tr.dataset.userid));
    });
    if (meta) {
      const page = Math.floor(meta.offset / meta.limit) + 1, pages = Math.ceil(meta.total / meta.limit) || 1;
      $("users-page-info").textContent = `Página ${page} de ${pages}`;
      $("users-prev").disabled = meta.offset === 0;
      $("users-next").disabled = meta.offset + meta.limit >= meta.total;
    }
  }

  async function openUserModal(userId) {
    $("user-modal-title").textContent = userId;
    $("user-modal-body").innerHTML = '<p class="loading-row">Cargando…</p>';
    $("user-modal").showModal();
    try {
      const res = await apiFetch("/users/" + encodeURIComponent(userId));
      const u = res.data;
      const rate = u.total_transactions > 0 ? ((u.fraud_count / u.total_transactions) * 100).toFixed(1) + "%" : "0%";
      const txRows = (u.recent_transactions || []).map(tx => `<tr>
        <td class="mono">${esc(tx.transaction_id)}</td>
        <td>${esc(fmtAmount(tx.amount, tx.currency))}</td>
        <td>${esc(tx.country)}</td>
        <td>${esc(tx.channel)}</td>
        <td>${esc(fmtPct(tx.fraud_score))}</td>
        <td>${decisionPill(tx.decision)}</td>
        <td>${esc(fmtDate(tx.processed_at))}</td>
      </tr>`).join("") || '<tr><td colspan="7" class="empty-row">Sin transacciones.</td></tr>';

      $("user-modal-body").innerHTML = `
        <div class="user-kpis">
          ${kpiCard(fmt(u.total_transactions), "Transacciones", "")}
          ${kpiCard(fmt(u.fraud_count), "Fraudes", u.fraud_count > 0 ? "danger" : "success")}
          ${kpiCard(rate, "Tasa fraude", u.fraud_count > 0 ? "danger" : "")}
          ${kpiCard(fmtPct(u.avg_fraud_score), "Score prom.", "")}
        </div>
        <h4>Últimas 10 transacciones</h4>
        <div class="table-wrap">
          <table>
            <thead><tr><th>ID</th><th>Monto</th><th>País</th><th>Canal</th><th>Score</th><th>Decisión</th><th>Procesada</th></tr></thead>
            <tbody>${txRows}</tbody>
          </table>
        </div>`;
    } catch (e) {
      $("user-modal-body").innerHTML = `<p class="error-text">${esc(e.message)}</p>`;
    }
  }

  // ── Bootstrap ──────────────────────────────────────────────────────────────
  function init() {
    // Login
    $("login-form").addEventListener("submit", e => {
      e.preventDefault();
      const u = $("login-user").value.trim(), p = $("login-pass").value;
      if (u === DEMO_USER && p === DEMO_PASS) {
        sessionStorage.setItem(SESSION_KEY, "1");
        $("login-error").textContent = "";
        showView("app");
      } else {
        $("login-error").textContent = "Usuario o contraseña incorrectos.";
      }
    });

    $("btn-logout").addEventListener("click", doLogout);
    $("btn-refresh").addEventListener("click", () => {
      const active = document.querySelector(".tab-btn.active");
      if (active) setTab(active.dataset.tab);
    });

    // Tabs
    qsa(".tab-btn").forEach(b => b.addEventListener("click", () => setTab(b.dataset.tab)));

    // Sortable headers (initialized once; re-fired on each load via updateSortHeaders)
    initSortHeaders("tx-table",    txState,    loadTransactions);
    initSortHeaders("users-table", usersState, loadUsers);

    // Global filters
    $("gf-apply").addEventListener("click", applyGlobalFilters);
    $("gf-clear").addEventListener("click", clearGlobalFilters);
    [$("gf-user"), $("gf-from"), $("gf-to")].forEach(el => {
      el.addEventListener("keydown", e => { if (e.key === "Enter") applyGlobalFilters(); });
    });

    // Transactions per-tab filters
    const txFilters = { "tx-filter-all": null, "tx-filter-fraud": true, "tx-filter-ok": false };
    Object.entries(txFilters).forEach(([id, val]) => {
      $(id).addEventListener("click", () => {
        txState.is_fraud = val; txState.offset = 0;
        Object.keys(txFilters).forEach(bid => $(bid).classList.toggle("active", bid === id));
        loadTransactions();
      });
    });
    $("tx-limit").addEventListener("change", e => { txState.limit = parseInt(e.target.value, 10); txState.offset = 0; loadTransactions(); });
    $("tx-prev").addEventListener("click",  () => { txState.offset = Math.max(0, txState.offset - txState.limit); loadTransactions(); });
    $("tx-next").addEventListener("click",  () => { txState.offset += txState.limit; loadTransactions(); });

    // Users pagination
    $("users-prev").addEventListener("click", () => { usersState.offset = Math.max(0, usersState.offset - usersState.limit); loadUsers(); });
    $("users-next").addEventListener("click", () => { usersState.offset += usersState.limit; loadUsers(); });

    // User modal
    $("user-modal-close").addEventListener("click", () => $("user-modal").close());
    $("user-modal").addEventListener("click", e => { if (e.target === e.currentTarget) e.currentTarget.close(); });

    if (isAuthed()) showView("app");
    else showView("login");
  }

  document.addEventListener("DOMContentLoaded", init);
})();
