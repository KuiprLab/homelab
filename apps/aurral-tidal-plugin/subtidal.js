const SUBTIDAL_API_VERSION = "1.16.1";

export function credentials(settings = {}) {
  const url = String(settings.url || "").trim().replace(/\/+$/, "");
  const username = String(settings.username || "").trim();
  const password = String(settings.password || "");
  if (!url) throw new Error("Set the subtidal URL in the plugin settings");
  if (!username) throw new Error("Set the subtidal username in the plugin settings");
  if (!password) throw new Error("Set the subtidal password in the plugin settings");
  return {url, username, password};
}

function endpoint(settings, method, params = {}) {
  const {url, username, password} = credentials(settings);
  const query = new URLSearchParams({
    v: SUBTIDAL_API_VERSION,
    c: "aurral",
    u: username,
    p: password,
    ...params,
  });
  return `${url}/rest/${method}.view?${query}`;
}

// A stream answers a real 404 when Tidal cannot serve the track, so the body
// carries the only usable reason; keep it in the message.
export function subsonicError(text) {
  try {
    const error = JSON.parse(String(text || ""))?.["subsonic-response"]?.error;
    if (error?.message) return `subtidal error ${error.code ?? "?"}: ${error.message}`;
  } catch {}
  return null;
}

export async function failureMessage(response) {
  return subsonicError(await response.text()) ?? `subtidal answered ${response.status}`;
}

export async function subtidalFile(settings, method, params = {}) {
  const response = await fetch(endpoint(settings, method, params));
  if (!response.ok) throw new Error(await failureMessage(response));
  return response;
}

export async function subtidal(settings, method, params = {}) {
  const response = await subtidalFile(settings, method, {f: "json", ...params});
  const body = await response.json();
  const payload = body?.["subsonic-response"];
  if (!payload) throw new Error("subtidal returned an unexpected answer");
  if (payload.status !== "ok") {
    const code = payload.error?.code;
    const message = payload.error?.message || "unknown error";
    throw new Error(`subtidal error ${code ?? "?"}: ${message}`);
  }
  return payload;
}
