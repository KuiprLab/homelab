const PLAYLIST_PATH = /\/playlist\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i;
const BARE_UUID = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const LIKED_PATH = /\/(?:my-collection\/tracks|liked(?:-songs|-tracks)?)(?:[/?#]|$)/i;
const UNAVAILABLE_MARKER = /\s*\(unavailable on Tidal\)$/i;
const MAX_TRACKS = 5000;
const SEARCH_LIMIT = 10;
const DURATION_TOLERANCE_MS = 5000;
const SUBTIDAL_API_VERSION = "1.16.1";

function parseLink(url) {
  const trimmed = String(url || "").trim();
  if (LIKED_PATH.test(trimmed)) return {kind: "liked"};
  const match = trimmed.match(PLAYLIST_PATH) || trimmed.match(BARE_UUID);
  if (!match) throw new Error("This is not a Tidal playlist link");
  return {kind: "playlist", id: match[1].toLowerCase()};
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

async function subtidal(settings, method, params = {}) {
  const response = await fetch(endpoint(settings, method, {f: "json", ...params}));
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

async function subtidalFile(settings, method, params = {}) {
  const response = await fetch(endpoint(settings, method, params));
  if (!response.ok) throw new Error(`subtidal answered ${response.status}`);
  return response;
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

function toResult(entry) {
  const id = String(entry?.id || "").trim();
  const artist = String(entry?.artist || "").trim();
  const title = String(entry?.title || "").trim();
  if (!id || !artist || !title) return null;
  const album = String(entry?.album || "").trim();
  const format = String(entry?.suffix || "").trim().toLowerCase();
  const bitrate = Number(entry?.bitRate);
  const seconds = Number(entry?.duration);
  return {
    id,
    title,
    artist,
    ...(album && {album}),
    ...(Number.isFinite(seconds) && seconds > 0 && {durationMs: seconds * 1000}),
    ...(format && {format}),
    ...(Number.isFinite(bitrate) && bitrate > 0 && {bitrate}),
    data: {tidalId: id},
  };
}

const normalize = (value) =>
  String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

// A wrong match would star an unrelated Tidal track, so demand the same title,
// an overlapping artist, and a duration within tolerance.
function pickId(songs, track) {
  const wantedTitle = normalize(track?.title);
  const wantedArtist = normalize(track?.artist);
  const wantedMs = Number(track?.durationMs);
  if (!wantedTitle) return null;
  const match = songs.find((entry) => {
    if (normalize(entry?.title) !== wantedTitle) return false;
    const artist = normalize(entry?.artist);
    if (wantedArtist && artist && !artist.includes(wantedArtist) && !wantedArtist.includes(artist)) {
      return false;
    }
    const seconds = Number(entry?.duration);
    if (
      Number.isFinite(wantedMs) &&
      wantedMs > 0 &&
      Number.isFinite(seconds) &&
      seconds > 0 &&
      Math.abs(seconds * 1000 - wantedMs) > DURATION_TOLERANCE_MS
    ) {
      return false;
    }
    return true;
  });
  return match ? String(match.id) : null;
}

function attachmentName(header, fallback) {
  const match = String(header || "").match(/filename="?([^";]+)"?/i);
  const base = match ? match[1].split(/[\\/]/).pop().trim() : "";
  return base && base !== "." && base !== ".." ? base : fallback;
}

async function searchSongs(settings, track) {
  const title = String(track?.title || "").trim();
  const artist = String(track?.artist || "").trim();
  if (!title) return [];
  const payload = await subtidal(settings, "search3", {
    query: [artist, title].filter(Boolean).join(" "),
    songCount: SEARCH_LIMIT,
    albumCount: 0,
    artistCount: 0,
  });
  return payload.searchResult3?.song || [];
}

async function likedTracks(settings) {
  const payload = await subtidal(settings, "getStarred2");
  const tracks = (payload.starred2?.song || []).map(toTrack).filter(Boolean).slice(0, MAX_TRACKS);
  if (tracks.length === 0) throw new Error("No liked songs on Tidal");
  return tracks;
}

async function findTidalId(settings, track) {
  if (!String(track?.title || "").trim()) return null;
  return pickId(await searchSongs(settings, track), track);
}

export default {
  async test({settings}) {
    const [playlists, favorites] = await Promise.all([
      subtidal(settings, "getPlaylists"),
      subtidal(settings, "getStarred2"),
    ]);
    const playlistCount = playlists.playlists?.playlist?.length || 0;
    const likedCount = favorites.starred2?.song?.length || 0;
    return {message: `Connected to subtidal: ${playlistCount} playlists, ${likedCount} liked songs`};
  },

  importList: {
    async fetch({url, settings}) {
      const link = parseLink(url);
      if (link.kind === "liked") return {name: "Liked songs", tracks: await likedTracks(settings)};
      const payload = await subtidal(settings, "getPlaylist", {id: link.id});
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

  downloadSource: {
    async search({settings, track}) {
      const songs = await searchSongs(settings, track);
      return songs.map(toResult).filter(Boolean);
    },

    async download({settings, result, directory}) {
      const tidalId = String(result?.data?.tidalId || result?.id || "").trim();
      if (!tidalId) throw new Error("This result has no Tidal track id");
      const response = await subtidalFile(settings, "download", {id: tidalId});
      const extension = String(result?.format || "flac").toLowerCase();
      const fileName = attachmentName(
        response.headers.get("content-disposition"),
        `${tidalId}.${extension}`,
      );
      const {writeFile} = await import("node:fs/promises");
      await writeFile(`${directory}/${fileName}`, Buffer.from(await response.arrayBuffer()));
      return {path: fileName};
    },
  },

  events: {
    async "download.finished"({settings, track}) {
      if (settings.starDownloads !== true) return;
      const tidalId = await findTidalId(settings, track);
      if (!tidalId) return;
      await subtidal(settings, "star", {id: tidalId});
    },
  },
};
