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
  // Optional Phase-1 controls — only sent when the user fills them in.
  const password = $("password").value;
  const maxDownloads = parseInt($("maxdl").value, 10);
  const notifyEmail = $("notify").value.trim();

  $("go").disabled = true;
  try {
    // 1. Ask the API for an upload link + metadata (with TTL).
    setStatus("Requesting upload link…");
    const reqBody = { filename: file.name, expiresInSeconds, contentLength: file.size };
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

    // 2. Upload the bytes straight to S3 with the presigned PUT URL.
    setStatus("Uploading…");
    const put = await fetch(uploadUrl, { method: "PUT", body: file });
    if (!put.ok) throw new Error(`upload failed (${put.status})`);

    // 3. The share link is the download PAGE — it prompts for a password when set.
    const shareLink = `${location.origin}/get.html?id=${fileId}`;
    $("shareLink").value = shareLink;
    const extras = [];
    if (password) extras.push("password-protected");
    if (Number.isInteger(maxDownloads) && maxDownloads > 0) extras.push(`max ${maxDownloads} download${maxDownloads > 1 ? "s" : ""}`);
    if (notifyEmail) extras.push("you'll be emailed on download");
    $("expiryNote").textContent =
      `Expires in ${$("expiry").selectedOptions[0].text.toLowerCase()}${extras.length ? " · " + extras.join(" · ") : ""}. Then it self-destructs.`;
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
