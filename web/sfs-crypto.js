// sfs-crypto.js — client-side, zero-knowledge encryption for Serverless File Share.
//
// AES-256-GCM runs entirely in the browser via the WebCrypto API. The key is
// generated here, travels ONLY in the share link's #fragment (which the web
// platform never sends to any server), and never touches AWS. Everything the
// backend stores is ciphertext — it cannot read the file, or even its name.
//
// On-disk (S3) blob layout:
//   [1 byte version=0x01][12-byte IV][ AES-GCM ciphertext + 16-byte tag ]
// The encrypted plaintext is itself framed so the filename is secret too:
//   [4-byte big-endian header length][ UTF-8 JSON header ][ file/note bytes ]
//   header = { n: <name>, t: <mime>, k: "file" | "note" }
(function (global) {
  "use strict";

  const VERSION = 0x01;
  const IV_LEN = 12; // 96-bit nonce, the AES-GCM standard

  // URL-safe base64 (no padding) — used to carry the raw key in the # fragment.
  const b64u = {
    encode(buf) {
      const arr = new Uint8Array(buf);
      let s = "";
      for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
      return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    },
    decode(str) {
      str = String(str).replace(/-/g, "+").replace(/_/g, "/");
      while (str.length % 4) str += "=";
      const bin = atob(str);
      const out = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
      return out;
    },
  };

  const genKey = () =>
    crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);

  const exportKey = async (key) => b64u.encode(await crypto.subtle.exportKey("raw", key));

  const importKey = (b64key) =>
    crypto.subtle.importKey("raw", b64u.decode(b64key), { name: "AES-GCM" }, false, ["decrypt"]);

  function frame(header, dataBytes) {
    const h = new TextEncoder().encode(JSON.stringify(header));
    const out = new Uint8Array(4 + h.length + dataBytes.length);
    new DataView(out.buffer).setUint32(0, h.length, false); // big-endian header length
    out.set(h, 4);
    out.set(dataBytes, 4 + h.length);
    return out;
  }

  function unframe(bytes) {
    const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const hlen = dv.getUint32(0, false);
    const header = JSON.parse(new TextDecoder().decode(bytes.subarray(4, 4 + hlen)));
    return { header, data: bytes.subarray(4 + hlen) };
  }

  // Encrypt -> { blob: Uint8Array ready to PUT, keyStr: string for the #fragment }.
  async function encrypt(header, dataBytes) {
    const key = await genKey();
    const iv = crypto.getRandomValues(new Uint8Array(IV_LEN));
    const ct = new Uint8Array(
      await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, frame(header, dataBytes))
    );
    const blob = new Uint8Array(1 + IV_LEN + ct.length);
    blob[0] = VERSION;
    blob.set(iv, 1);
    blob.set(ct, 1 + IV_LEN);
    return { blob, keyStr: await exportKey(key) };
  }

  // Decrypt an S3 blob with the key from the fragment -> { header, data }.
  async function decrypt(blobBuf, b64key) {
    const bytes = new Uint8Array(blobBuf);
    if (bytes[0] !== VERSION) throw new Error("Unsupported link format.");
    const iv = bytes.subarray(1, 1 + IV_LEN);
    const ct = bytes.subarray(1 + IV_LEN);
    const key = await importKey(b64key);
    let plain;
    try {
      plain = new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, ct));
    } catch (_e) {
      throw new Error("Decryption failed — wrong key in the link, or the file was tampered with.");
    }
    return unframe(plain);
  }

  global.SFSCrypto = { encrypt, decrypt, b64u };
})(window);
