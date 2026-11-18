const PLAYLIST_PATH = /\/playlist\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i;
const BARE_UUID = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const UNAVAILABLE_MARKER = /\s*\(unavailable on Tidal\)$/i;
const MAX_TRACKS = 5000;
const SUBTIDAL_API_VERSION = "1.16.1";

function parsePlaylistId(url) {
  const trimmed = String(url || "").trim();
  const match = trimmed.match(PLAYLIST_PATH) || trimmed.match(BARE_UUID);
  if (!match) throw new Error("This is not a Tidal playlist link");
  return match[1].toLowerCase();
}

function credentials(settings = {}) {
  const url = String(settings.url || "").trim().replace(/\/+$/, "");
  const username = String(settings.username || "").trim();
  const password = String(settings.password || "");
  if (!url) throw new Error("Set the subtidal URL in the plugin settings");
  if (!username) throw new Error("Set the subtidal username in the plugin settings");
  if (!password) throw new Error("Set the subtidal password in the plugin settings");
  return {url, username, password};
}

async function subtidal(settings, method, params = {}) {
  const {url, username, password} = credentials(settings);
  const query = new URLSearchParams({
    v: SUBTIDAL_API_VERSION,
    c: "aurral",
    f: "json",
    u: username,
    p: password,
    ...params,
  });
  const response = await fetch(`${url}/rest/${method}.view?${query}`);
  if (!response.ok) throw new Error(`subtidal answered ${response.status}`);
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

function toTrack(entry) {
  const artist = String(entry?.artist || "").trim();
  const title = String(entry?.title || "").trim().replace(UNAVAILABLE_MARKER, "");
  if (!artist || !title) return null;
  const album = String(entry?.album || "").trim();
  const seconds = Number(entry?.duration);
  return {
    artist,
    title,
    ...(album && {album}),
    ...(Number.isFinite(seconds) && seconds > 0 && {durationMs: seconds * 1000}),
  };
}

export default {
  async test({settings}) {
    const payload = await subtidal(settings, "getPlaylists");
    const playlists = payload.playlists?.playlist || [];
    return {message: `Connected to subtidal: ${playlists.length} playlists`};
  },

  importList: {
    async fetch({url, settings}) {
      const id = parsePlaylistId(url);
      const payload = await subtidal(settings, "getPlaylist", {id});
      const playlist = payload.playlist;
      if (!playlist) throw new Error("Playlist not found on Tidal");
      const tracks = (playlist.entry || [])
        .map(toTrack)
        .filter(Boolean)
        .slice(0, MAX_TRACKS);
      if (tracks.length === 0) throw new Error("Playlist has no tracks on Tidal");
      return {name: playlist.name, tracks};
    },
  },
};
