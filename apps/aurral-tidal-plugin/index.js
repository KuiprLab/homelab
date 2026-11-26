import {appendLog} from "./journal.js";

const PLAYLIST_PATH = /\/playlist\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i;
const BARE_UUID = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const LIKED_PATH = /\/(?:my-collection\/tracks|liked(?:-songs|-tracks)?)(?:[/?#]|$)/i;
const UNAVAILABLE_MARKER = /\s*\(unavailable on Tidal\)$/i;
const MAX_TRACKS = 5000;
const SEARCH_LIMIT = 40;
const DURATION_TOLERANCE_MS = 5000;

function parseLink(url) {
  const trimmed = String(url || "").trim();
  if (LIKED_PATH.test(trimmed)) return {kind: "liked"};
  const match = trimmed.match(PLAYLIST_PATH) || trimmed.match(BARE_UUID);
  if (!match) throw new Error("This is not a Tidal playlist link");
  return {kind: "playlist", id: match[1].toLowerCase()};
}

const normalize = (value) =>
  String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

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

// Tidal indexes a featured credit inside the title, so a request that carries it
// through can miss the plain entry. The title alone is the fallback.
function queryVariants(track) {
  const artist = String(track?.artist || "").trim();
  const title = String(track?.title || "").trim();
  if (!title) return [];
  const plain = title.replace(/\s*[([-]\s*(?:feat|ft|featuring)\.?[^)\]]*[)\]]?/i, "").trim();
  const candidates = [[artist, title].filter(Boolean).join(" "), title, plain];
  return [...new Set(candidates.filter(Boolean))];
}

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

async function subtidal(settings, method, params = {}) {
  const url = String(settings.url || "").trim().replace(/\/+$/, "");
  const username = String(settings.username || "").trim();
  const password = String(settings.password || "").trim();
  if (!url) throw new Error("Set the subtidal URL in the plugin settings");
  if (!username) throw new Error("Set the subtidal username in the plugin settings");
  if (!password) throw new Error("Set the subtidal password in the plugin settings");
  const query = new URLSearchParams({
    v: "1.16.1",
    c: "aurral",
    f: "json",
    u: username,
    p: password,
    ...params,
  });
  const response = await fetch(`${url}/rest/${method}.view?${query}`);
  if (!response.ok) {
    let body;
    try {
      body = await response.json();
    } catch {}
    const error = body?.["subsonic-response"]?.error;
    const message = error?.message ? `subtidal error ${error.code ?? "?"}: ${error.message}` : `subtidal answered ${response.status}`;
    throw new Error(message);
  }
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

async function searchSongs(settings, query, limit = SEARCH_LIMIT) {
  if (!query) return [];
  const payload = await subtidal(settings, "search3", {
    query,
    songCount: limit,
    albumCount: 0,
    artistCount: 0,
  });
  return payload.searchResult3?.song || [];
}

// aurral drops repeated artist/title/album rows when it saves a synced playlist,
// so the fetch is the only place where the repeats still exist.
const identity = (track) =>
  [track.artist, track.title, track.album]
    .map((value) =>
      String(value || "")
        .trim()
        .toLowerCase(),
    )
    .join("\u0001");

function logRepeats(label, tracks) {
  const firstSeen = new Map();
  const repeats = [];
  for (const [index, track] of tracks.entries()) {
    const key = identity(track);
    if (firstSeen.has(key)) repeats.push({index: index + 1, first: firstSeen.get(key), track});
    else firstSeen.set(key, index + 1);
  }
  if (repeats.length === 0) return;
  console.warn(`${label}: ${repeats.length} of ${tracks.length} entries repeat an earlier one`);
  for (const {index, first, track} of repeats.slice(0, 100)) {
    const album = track.album ? ` (${track.album})` : "";
    console.warn(`${label}: #${index} repeats #${first}: ${track.artist} - ${track.title}${album}`);
  }
}

async function likedTracks(settings) {
  const payload = await subtidal(settings, "getStarred2");
  const tracks = (payload.starred2?.song || []).map(toTrack).filter(Boolean).slice(0, MAX_TRACKS);
  if (tracks.length === 0) throw new Error("No liked songs on Tidal");
  logRepeats("Liked songs", tracks);
  return tracks;
}

async function findTidalId(settings, track) {
  const [query] = queryVariants(track);
  if (!query) return null;
  return pickId(await searchSongs(settings, query), track);
}

// aurral calls downloadSource.download with logFailures off, so a failure here
// would otherwise vanish and the job would silently fall to the next source.
async function logged(dataFolder, label, run) {
  try {
    return await run();
  } catch (error) {
    const reason = error?.message || String(error);
    console.warn(`${label} failed: ${reason}`);
    await appendLog(dataFolder, {kind: "failure", label, reason});
    throw error;
  }
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
      logRepeats(playlist.name || "Playlist", tracks);
      return {name: playlist.name, tracks};
    },
  },

  events: {
    async "download.finished"({settings, track, dataFolder}) {
      if (settings.starDownloads !== true) return;
      const tidalId = await findTidalId(settings, track);
      if (!tidalId) return;
      await logged(dataFolder, `star ${track.artist} - ${track.title}`, async () => {
        await subtidal(settings, "star", {id: tidalId});
      });
    },
  },
};
