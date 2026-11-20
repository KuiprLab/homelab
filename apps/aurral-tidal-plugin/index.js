import {albumFileName, taggedFileName, writeTrack} from "./audio.js";
import {appendLog} from "./journal.js";
import {normalize, pickId, toAlbumResult, toResult, toTrack} from "./mapping.js";
import {subtidal} from "./subtidal.js";

const PLAYLIST_PATH = /\/playlist\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i;
const BARE_UUID = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const LIKED_PATH = /\/(?:my-collection\/tracks|liked(?:-songs|-tracks)?)(?:[/?#]|$)/i;
const MAX_TRACKS = 5000;
const SEARCH_LIMIT = 40;

function parseLink(url) {
  const trimmed = String(url || "").trim();
  if (LIKED_PATH.test(trimmed)) return {kind: "liked"};
  const match = trimmed.match(PLAYLIST_PATH) || trimmed.match(BARE_UUID);
  if (!match) throw new Error("This is not a Tidal playlist link");
  return {kind: "playlist", id: match[1].toLowerCase()};
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

async function likedTracks(settings) {
  const payload = await subtidal(settings, "getStarred2");
  const tracks = (payload.starred2?.song || []).map(toTrack).filter(Boolean).slice(0, MAX_TRACKS);
  if (tracks.length === 0) throw new Error("No liked songs on Tidal");
  return tracks;
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

async function findTidalId(settings, track) {
  const [query] = queryVariants(track);
  if (!query) return null;
  return pickId(await searchSongs(settings, query), track);
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
    async search({settings, track, dataFolder}) {
      const queries = queryVariants(track);
      const found = new Map();
      for (const query of queries) {
        for (const entry of await searchSongs(settings, query)) {
          const result = toResult(entry);
          if (result && !found.has(result.id)) found.set(result.id, result);
        }
      }
      const results = [...found.values()];
      await appendLog(dataFolder, {
        kind: "search",
        track: `${track?.artist ?? "?"} - ${track?.title ?? "?"}`,
        queries,
        returned: results.length,
        titles: results.slice(0, 8).map((result) => `${result.artist} - ${result.title}`),
      });
      if (results.length === 0) {
        console.warn(`no Tidal match for ${track?.artist ?? "?"} - ${track?.title ?? "?"}`);
        return results;
      }
      // An exact title wins the pick, but variants stay: aurral's own identity
      // gate rejects a wrong one and falls to the next source.
      const wantedTitle = normalize(track?.title);
      if (!wantedTitle) return results;
      const exact = results.filter((result) => normalize(result.title) === wantedTitle);
      const rest = results.filter((result) => normalize(result.title) !== wantedTitle);
      return [...exact, ...rest];
    },

    async download({settings, result, directory, dataFolder}) {
      const tidalId = String(result?.data?.tidalId || result?.id || "").trim();
      if (!tidalId) throw new Error("This result has no Tidal track id");
      return await logged(dataFolder, `${result?.artist ?? "?"} - ${result?.title ?? "?"}`, async () => {
        const fileName = await writeTrack(
          settings,
          directory,
          tidalId,
          result,
          (extension) => taggedFileName(result, extension) ?? `${tidalId}.${extension}`,
        );
        return {path: fileName};
      });
    },

    async searchAlbum({settings, album, dataFolder}) {
      const title = String(album?.title || "").trim();
      const artist = String(album?.artist || "").trim();
      if (!title) return [];
      const query = [artist, title].filter(Boolean).join(" ");
      const payload = await subtidal(settings, "search3", {
        query,
        albumCount: SEARCH_LIMIT,
        songCount: 0,
        artistCount: 0,
      });
      const results = (payload.searchResult3?.album || []).map(toAlbumResult).filter(Boolean);
      await appendLog(dataFolder, {
        kind: "searchAlbum",
        album: `${artist || "?"} - ${title}`,
        query,
        returned: results.length,
        titles: results.slice(0, 8).map((result) => `${result.artist} - ${result.title}`),
      });
      if (results.length === 0) console.warn(`no Tidal album for ${artist || "?"} - ${title}`);
      return results;
    },

    async downloadAlbum({settings, result, directory, dataFolder}) {
      const albumId = String(result?.data?.albumId || result?.id || "").trim();
      if (!albumId) throw new Error("This result has no Tidal album id");
      return await logged(dataFolder, `album ${result?.artist ?? "?"} - ${result?.title ?? "?"}`, async () => {
        const payload = await subtidal(settings, "getAlbum", {id: albumId});
        const songs = payload.album?.song || [];
        if (songs.length === 0) throw new Error("Album has no tracks on Tidal");
        for (const [index, entry] of songs.entries()) {
          const tidalId = String(entry?.id || "").trim();
          if (!tidalId) continue;
          await writeTrack(settings, directory, tidalId, entry, (extension) =>
            albumFileName(entry, index + 1, extension),
          );
        }
      });
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
