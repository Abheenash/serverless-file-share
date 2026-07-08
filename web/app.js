// Serverless File Share — front end. Talks to the API defined in config.js.
const API_BASE = (window.SFS_CONFIG || {}).apiBase;

const $ = (id) => document.getElementById(id);
const status = $("status");

function setStatus(msg, isError = false) {
  status.textContent = msg;
  status.className = "status" + (isError ? " err" : "");
}

$("go").addEventListener("click", async () => {
  const file = $("file").files[0];
  if (!file) return setStatus("Pick a file first.", true);
  if (!API_BASE) return setStatus("config.js is missing apiBase.", true);

  const expiresInSeconds = parseInt($("expiry").value, 10);
  $("go").disabled = true;
  try {
    // 1. Ask the API for an upload link + metadata (with TTL).
    setStatus("Requesting upload link…");
    const issue = await fetch(`${API_BASE}/files`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ filename: file.name, expiresInSeconds, contentLength: file.size }),
    });
    if (!issue.ok) throw new Error(`issue-url failed (${issue.status})`);
    const { fileId, uploadUrl } = await issue.json();

    // 2. Upload the bytes straight to S3 with the presigned PUT URL.
    setStatus("Uploading…");
    const put = await fetch(uploadUrl, { method: "PUT", body: file });
    if (!put.ok) throw new Error(`upload failed (${put.status})`);

    // 3. The share link is our own API URL — it 302s to a fresh download.
    const shareLink = `${API_BASE}/files/${fileId}`;
    $("shareLink").value = shareLink;
    $("expiryNote").textContent =
      `Link expires in ${$("expiry").selectedOptions[0].text.toLowerCase()}. After that it self-destructs.`;
    $("result").style.display = "block";
    setStatus("Done ✓");
  } catch (err) {
    setStatus(err.message, true);
  } finally {
    $("go").disabled = false;
  }
});

$("copy").addEventListener("click", () => {
  const el = $("shareLink");
  el.select();
  navigator.clipboard.writeText(el.value);
});
