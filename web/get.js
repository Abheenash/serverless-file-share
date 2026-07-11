// Download page — resolves ?id=<fileId> against the API, prompts for a password
// when the link is protected, and enforces the download limit server-side.
const API_BASE = (window.SFS_CONFIG || {}).apiBase;
const body = document.getElementById("body");
const fileId = new URLSearchParams(location.search).get("id");

const esc = (s) => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function gone(msg) {
  body.innerHTML = `<div class="gone"><div class="big">💨</div>
    <div class="fname">This link is gone</div>
    <div class="msg">${esc(msg)}</div></div>`;
}

function fmtLeft(secs) {
  if (secs <= 0) return "expired";
  const h = Math.floor(secs / 3600), m = Math.floor((secs % 3600) / 60);
  if (h >= 24) return `${Math.floor(h / 24)}d ${h % 24}h`;
  if (h) return `${h}h ${m}m`;
  return `${m}m`;
}

async function load() {
  if (!API_BASE) return gone("Client misconfigured (no API base).");
  if (!fileId) return gone("No file id in the link.");
  let info;
  try {
    const r = await fetch(`${API_BASE}/files/${fileId}`);
    info = await r.json().catch(() => ({}));
    if (r.status === 410 || info.gone) return gone(info.error || "It expired or hit its download limit.");
    if (!r.ok) return gone("Something went wrong resolving this link.");
  } catch (_e) {
    return gone("Network error resolving this link.");
  }
  render(info);
}

function render(info) {
  const now = Math.floor(Date.now() / 1000);
  const left = info.downloadsLeft;
  const rows = [
    `<div><span>Expires in</span><b>${esc(fmtLeft(info.expiresAt - now))}</b></div>`,
    left != null ? `<div><span>Downloads left</span><b>${left}</b></div>` : "",
    `<div><span>Protected</span><b>${info.passwordProtected ? "🔒 password" : "public link"}</b></div>`,
  ].join("");

  body.innerHTML = `
    <div class="fname">${esc(info.filename || "Shared file")}</div>
    <div class="lock">Someone shared this file with you. It self-destructs on a timer.</div>
    <div class="kv">${rows}</div>
    ${info.passwordProtected ? `
      <label for="pw">Password</label>
      <input type="password" id="pw" placeholder="Enter the password" autocomplete="off" />` : ""}
    <button id="dl">${info.passwordProtected ? "Unlock & download" : "Download"}</button>
    <div class="status" id="st"></div>`;

  const btn = document.getElementById("dl");
  const st = document.getElementById("st");
  const pw = document.getElementById("pw");
  const setSt = (m, cls = "") => { st.textContent = m; st.className = "status " + cls; };
  if (pw) pw.addEventListener("keydown", e => { if (e.key === "Enter") btn.click(); });

  btn.addEventListener("click", async () => {
    btn.disabled = true; setSt("Preparing your download…");
    try {
      const r = await fetch(`${API_BASE}/files/${fileId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(pw ? { password: pw.value } : {}),
      });
      const d = await r.json().catch(() => ({}));
      if (r.status === 401) { setSt("Incorrect password — try again.", "err"); btn.disabled = false; return; }
      if (r.status === 410) { return gone(d.error || "This link is no longer available."); }
      if (!r.ok || !d.downloadUrl) { setSt("Couldn't start the download. Try again.", "err"); btn.disabled = false; return; }
      setSt("Download starting ✓", "ok");
      window.location = d.downloadUrl; // S3 serves it as an attachment
    } catch (_e) {
      setSt("Network error — please retry.", "err"); btn.disabled = false;
    }
  });
}

load();
