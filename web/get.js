// Download page — end-to-end decryption happens HERE, in the recipient's browser.
//
// Flow: resolve ?id=<fileId> for metadata -> (prompt for password if set) ->
// POST to spend a download + get a short-lived presigned URL -> fetch the
// CIPHERTEXT -> read the key from location.hash -> decrypt locally -> hand over
// the file (or show the note). The key never leaves the browser.
const API_BASE = (window.SFS_CONFIG || {}).apiBase;
const body = document.getElementById("body");
const fileId = new URLSearchParams(location.search).get("id");
const keyStr = location.hash ? location.hash.slice(1) : "";

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

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
    `<div><span>Encryption</span><b>${info.encrypted ? "🔐 end-to-end (in your browser)" : "SSE-KMS"}</b></div>`,
    `<div><span>Protected</span><b>${info.passwordProtected ? "🔒 password" : "link only"}</b></div>`,
  ].join("");

  const noKey = info.encrypted && !keyStr;

  body.innerHTML = `
    <div class="fname">🔒 Encrypted ${info.encrypted ? "item" : "file"}</div>
    <div class="lock">${info.encrypted
      ? "Its name and contents are sealed — they’re revealed only after your browser decrypts it locally."
      : "Someone shared this file with you. It self-destructs on a timer."}</div>
    <div class="kv">${rows}</div>
    ${noKey ? `<div class="status err">This link is missing its decryption key (the part after “#”). It can’t be decrypted — ask the sender for the full link.</div>` : `
      ${info.passwordProtected ? `
        <label for="pw">Password</label>
        <input type="password" id="pw" placeholder="Enter the password" autocomplete="off" />` : ""}
      <button id="dl">${info.passwordProtected ? "Unlock & decrypt" : "Decrypt & download"}</button>`}
    <div class="status" id="st"></div>
    <div id="out"></div>`;

  if (noKey) return;

  const btn = document.getElementById("dl");
  const st = document.getElementById("st");
  const pw = document.getElementById("pw");
  const setSt = (m, cls = "") => { st.textContent = m; st.className = "status " + cls; };
  if (pw) pw.addEventListener("keydown", (e) => { if (e.key === "Enter") btn.click(); });

  btn.addEventListener("click", async () => {
    btn.disabled = true;
    setSt("Requesting the encrypted bytes…");
    try {
      // 1. Spend a download and get a short-lived presigned GET.
      const r = await fetch(`${API_BASE}/files/${fileId}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(pw ? { password: pw.value } : {}),
      });
      const d = await r.json().catch(() => ({}));
      if (r.status === 401) { setSt("Incorrect password — try again.", "err"); btn.disabled = false; return; }
      if (r.status === 410) return gone(d.error || "This link is no longer available.");
      if (!r.ok || !d.downloadUrl) { setSt("Couldn't start the download. Try again.", "err"); btn.disabled = false; return; }

      // 2. Fetch the ciphertext from S3.
      setSt("Downloading & decrypting in your browser…");
      const cipher = await (await fetch(d.downloadUrl)).arrayBuffer();

      // 3. Decrypt locally with the key from the #fragment.
      if (info.encrypted) {
        const { header, data } = await SFSCrypto.decrypt(cipher, keyStr);
        if (header.k === "note") return showNote(header, data, setSt);
        return deliverFile(header.n, header.t, data, setSt);
      }
      // Legacy (non-E2EE) links: just hand over what S3 returned.
      deliverFile(info.filename || "download", "application/octet-stream", new Uint8Array(cipher), setSt);
    } catch (e) {
      setSt(e.message || "Something went wrong.", "err");
      btn.disabled = false;
    }
  });
}

function deliverFile(name, type, bytes, setSt) {
  const url = URL.createObjectURL(new Blob([bytes], { type: type || "application/octet-stream" }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name || "download";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
  setSt(`Decrypted ✓ — “${name}” saved to your downloads.`, "ok");
}

function showNote(header, bytes, setSt) {
  const text = new TextDecoder().decode(bytes);
  setSt("Decrypted ✓", "ok");
  const out = document.getElementById("out");
  out.innerHTML = `
    <label style="margin-top:1rem">Secret note</label>
    <textarea id="notetext" readonly style="width:100%;min-height:120px;padding:.6rem;border:1px solid var(--border);border-radius:8px;font:13px/1.5 monospace;resize:vertical"></textarea>
    <button id="copynote" style="margin-top:.7rem">Copy note</button>`;
  document.getElementById("notetext").value = text;
  document.getElementById("copynote").addEventListener("click", () => {
    navigator.clipboard.writeText(text);
    document.getElementById("copynote").textContent = "Copied ✓";
  });
}

load();
