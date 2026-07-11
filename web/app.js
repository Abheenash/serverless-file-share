// Serverless File Share — front end.
//
// Every share is END-TO-END ENCRYPTED. The file (or secret note) is encrypted in
// this browser with a fresh AES-256-GCM key BEFORE it is uploaded. Only ciphertext
// reaches S3. The key is placed in the share link's #fragment, which the browser
// never transmits — so the API, the Lambdas, S3, and I only ever see ciphertext.
const API_BASE = (window.SFS_CONFIG || {}).apiBase;
const MAX_BYTES = 100 * 1024 * 1024; // mirror of the backend cap (100 MB)

const $ = (id) => document.getElementById(id);
const status = $("status");
const setStatus = (msg, isError = false) => {
  status.textContent = msg;
  status.className = "status" + (isError ? " err" : "");
};

// ---- mode toggle: File vs Secret note -------------------------------------
let mode = "file";
let picked = null; // the chosen File in file mode
function setMode(next) {
  mode = next;
  $("tab-file").classList.toggle("on", next === "file");
  $("tab-note").classList.toggle("on", next === "note");
  $("pane-file").hidden = next !== "file";
  $("pane-note").hidden = next !== "note";
  setStatus("");
}
$("tab-file").addEventListener("click", () => setMode("file"));
$("tab-note").addEventListener("click", () => setMode("note"));

// ---- drag & drop + file picker --------------------------------------------
const drop = $("drop");
const fileInput = $("file");
function showPicked(f) {
  picked = f;
  if (!f) { $("drop-label").textContent = "Drop a file here, or click to browse"; return; }
  const kb = f.size < 1024 ? `${f.size} B` : f.size < 1048576 ? `${(f.size / 1024).toFixed(0)} KB` : `${(f.size / 1048576).toFixed(1)} MB`;
  $("drop-label").textContent = `${f.name} · ${kb}`;
}
drop.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", () => showPicked(fileInput.files[0] || null));
["dragenter", "dragover"].forEach((e) =>
  drop.addEventListener(e, (ev) => { ev.preventDefault(); drop.classList.add("over"); }));
["dragleave", "drop"].forEach((e) =>
  drop.addEventListener(e, (ev) => { ev.preventDefault(); drop.classList.remove("over"); }));
drop.addEventListener("drop", (ev) => {
  const f = ev.dataTransfer.files[0];
  if (f) { showPicked(f); }
});

// ---- burn-after-reading toggle drives the download-limit field -------------
$("burn").addEventListener("change", () => {
  const on = $("burn").checked;
  $("maxdl").disabled = on;
  if (on) $("maxdl").value = "";
});

// ---- create the link -------------------------------------------------------
$("go").addEventListener("click", async () => {
  if (!API_BASE) return setStatus("config.js is missing apiBase.", true);
  if (!window.crypto || !crypto.subtle) return setStatus("This browser can't do WebCrypto (needs HTTPS).", true);

  // Gather the payload (file bytes or note text) + a header we encrypt alongside it.
  let dataBytes, header, sizeForCap;
  try {
    if (mode === "file") {
      if (!picked) return setStatus("Pick a file first.", true);
      if (picked.size > MAX_BYTES) return setStatus("File too large (100 MB max).", true);
      dataBytes = new Uint8Array(await picked.arrayBuffer());
      header = { n: picked.name, t: picked.type || "application/octet-stream", k: "file" };
    } else {
      const text = $("note").value;
      if (!text.trim()) return setStatus("Type a note first.", true);
      dataBytes = new TextEncoder().encode(text);
      header = { n: "note.txt", t: "text/plain", k: "note" };
    }
  } catch (e) {
    return setStatus("Couldn't read the input: " + e.message, true);
  }

  const expiresInSeconds = parseInt($("expiry").value, 10);
  const password = $("password").value;
  const burn = $("burn").checked;
  const maxDownloads = burn ? 1 : parseInt($("maxdl").value, 10);
  const notifyEmail = $("notify").value.trim();

  $("go").disabled = true;
  try {
    // 1. Encrypt locally. Nothing plaintext leaves this point.
    setStatus("🔒 Encrypting in your browser…");
    const { blob, keyStr } = await SFSCrypto.encrypt(header, dataBytes);
    if (blob.byteLength > MAX_BYTES) return setStatus("Encrypted payload too large (100 MB max).", true);

    // 2. Ask the API for a presigned upload URL. We send only the CIPHERTEXT
    //    length and a generic name — never the real filename or contents.
    setStatus("Requesting upload link…");
    const reqBody = {
      filename: "encrypted.bin",
      encrypted: true,
      expiresInSeconds,
      contentLength: blob.byteLength,
    };
    if (password) reqBody.password = password;
    if (Number.isInteger(maxDownloads) && maxDownloads > 0) reqBody.maxDownloads = maxDownloads;
    if (notifyEmail) reqBody.notifyEmail = notifyEmail;

    const issue = await fetch(`${API_BASE}/files`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(reqBody),
    });
    if (!issue.ok) throw new Error(`issue-url failed (${issue.status})`);
    const { fileId, uploadUrl } = await issue.json();

    // 3. Upload the ciphertext straight to S3 via the presigned PUT.
    setStatus("Uploading encrypted bytes…");
    const put = await fetch(uploadUrl, {
      method: "PUT",
      body: new Blob([blob], { type: "application/octet-stream" }),
    });
    if (!put.ok) throw new Error(`upload failed (${put.status})`);

    // 4. The key rides in the #fragment — appended client-side, never sent to the API.
    const shareLink = `${location.origin}/get.html?id=${fileId}#${keyStr}`;
    showResult(shareLink, { password, maxDownloads, notifyEmail, burn, kind: header.k });
    setStatus("Done ✓ — encrypted end-to-end.");
  } catch (err) {
    setStatus(err.message, true);
  } finally {
    $("go").disabled = false;
  }
});

function showResult(shareLink, opts) {
  $("shareLink").value = shareLink;
  const extras = [opts.kind === "note" ? "encrypted note" : "encrypted file"];
  if (opts.password) extras.push("password-protected");
  if (opts.burn) extras.push("burns after 1 download");
  else if (Number.isInteger(opts.maxDownloads) && opts.maxDownloads > 0)
    extras.push(`max ${opts.maxDownloads} download${opts.maxDownloads > 1 ? "s" : ""}`);
  if (opts.notifyEmail) extras.push("you'll be emailed on download");
  $("expiryNote").textContent =
    `Zero-knowledge: the key lives after the “#”, so only someone with this exact link can decrypt. ${extras.join(" · ")}. Then it self-destructs.`;

  // QR of the link (progressive enhancement — only if the vendored lib loaded).
  const qrBox = $("qr");
  qrBox.innerHTML = "";
  if (typeof qrcode === "function") {
    try {
      const qr = qrcode(0, "M");
      qr.addData(shareLink);
      qr.make();
      qrBox.innerHTML = qr.createSvgTag({ cellSize: 4, margin: 2, scalable: true });
      qrBox.hidden = false;
    } catch (_e) { qrBox.hidden = true; }
  } else {
    qrBox.hidden = true;
  }
  $("result").style.display = "block";
}

$("copy").addEventListener("click", () => {
  const el = $("shareLink");
  el.select();
  navigator.clipboard.writeText(el.value);
  $("copy").textContent = "Copied ✓";
  setTimeout(() => ($("copy").textContent = "Copy"), 1500);
});
