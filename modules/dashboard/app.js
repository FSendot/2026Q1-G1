(function () {
  const FAKE_USER = "cloud";
  const FAKE_PASS = "cloud";
  const SESSION_KEY = "fd_demo_session";

  const base = window.API_BASE || "";
  const viewLogin = document.getElementById("view-login");
  const viewApp = document.getElementById("view-app");
  const loginForm = document.getElementById("login-form");
  const loginError = document.getElementById("login-error");
  const statusEl = document.getElementById("status");
  const statusDot = document.getElementById("status-dot");
  const statsEl = document.getElementById("stats");
  const tableBody = document.querySelector("#tx-table tbody");
  const errEl = document.getElementById("error");

  function showError(msg) {
    errEl.textContent = msg;
    errEl.hidden = false;
  }

  function clearError() {
    errEl.textContent = "";
    errEl.hidden = true;
  }

  function isSessionOk() {
    return sessionStorage.getItem(SESSION_KEY) === "1";
  }

  function showApp() {
    viewLogin.style.display = "none";
    viewApp.classList.add("is-visible");
    load();
  }

  function showLogin() {
    sessionStorage.removeItem(SESSION_KEY);
    viewLogin.style.display = "";
    viewApp.classList.remove("is-visible");
    loginError.textContent = "";
    document.getElementById("password").value = "";
  }

  loginForm.addEventListener("submit", function (e) {
    e.preventDefault();
    var u = document.getElementById("username").value.trim();
    var p = document.getElementById("password").value;
    if (u === FAKE_USER && p === FAKE_PASS) {
      loginError.textContent = "";
      sessionStorage.setItem(SESSION_KEY, "1");
      showApp();
    } else {
      loginError.textContent = "Usuario o contraseña incorrectos.";
    }
  });

  document.getElementById("logout").addEventListener("click", showLogin);

  async function fetchJson(path) {
    var url = base.replace(/\/$/, "") + path;
    var res = await fetch(url, { headers: { Accept: "application/json" } });
    if (!res.ok) {
      throw new Error("HTTP " + res.status + " en " + url);
    }
    return res.json();
  }

  function pillClass(decision) {
    var d = String(decision || "").toLowerCase();
    if (d === "allow" || d === "allowed") return "pill allow";
    if (d === "challenge" || d === "challenged") return "pill challenge";
    if (d === "block" || d === "blocked") return "pill block";
    return "pill";
  }

  function pillLabel(decision) {
    var d = String(decision || "").toLowerCase();
    if (d === "allow" || d === "allowed") return "Permitida";
    if (d === "challenge" || d === "challenged") return "Challenge";
    if (d === "block" || d === "blocked") return "Bloqueada";
    return escapeHtml(decision || "—");
  }

  async function load() {
    if (!isSessionOk()) return;
    clearError();
    statusEl.textContent = "Comprobando API…";
    statusDot.classList.remove("offline");

    try {
      var health = await fetchJson("/health");
      statusEl.textContent =
        health.status === "ok" ? "API en línea" : "Respuesta inesperada";
      if (health.status !== "ok") statusDot.classList.add("offline");
    } catch (e) {
      statusEl.textContent = "Sin conexión";
      statusDot.classList.add("offline");
      showError("No se pudo contactar la API. Revisá API_BASE en config.js.");
      return;
    }

    try {
      var stats = await fetchJson("/api/stats");
      statsEl.innerHTML = [
        statHtml(stats.total, "Transacciones"),
        statHtml(stats.allowed, "Permitidas"),
        statHtml(stats.challenged, "Challenge"),
        statHtml(stats.blocked, "Bloqueadas"),
      ].join("");

      var tx = await fetchJson("/api/transactions?limit=10");
      tableBody.innerHTML = "";
      (tx.transactions || []).forEach(function (row) {
        var tr = document.createElement("tr");
        var decision = row.decision || "";
        var score = row.fraud_score != null
          ? (row.fraud_score * 100).toFixed(0) + "%"
          : "—";
        tr.innerHTML =
          "<td>" + escapeHtml(row.transaction_id) +
          "</td><td>" + escapeHtml(row.user_id || "—") +
          "</td><td>" + escapeHtml(row.amount != null ? String(row.amount) : "—") +
          " " + escapeHtml(row.currency || "") +
          "</td><td>" + escapeHtml(row.country || "—") +
          "</td><td>" + escapeHtml(score) +
          "</td><td><span class=\"" + pillClass(decision) + "\">" +
          pillLabel(decision) +
          "</span></td><td>" + escapeHtml(row.processed_at || "") + "</td>";
        tableBody.appendChild(tr);
      });
    } catch (e) {
      showError(e.message || String(e));
    }
  }

  function statHtml(value, label) {
    return (
      '<div class="stat"><div class="value">' +
      escapeHtml(String(value != null ? value : "—")) +
      '</div><div class="label">' +
      escapeHtml(label) +
      "</div></div>"
    );
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  document.getElementById("reload").addEventListener("click", load);

  if (isSessionOk()) {
    showApp();
  }
})();
