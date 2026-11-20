import {albumFileName, taggedFileName, writeTrack} from "./audio.js";
import {normalize, pickId, toAlbumResult, toResult, toTrack} from "./mapping.js";
import {subtidal} from "./subtidal.js";

const PLAYLIST_PATH = /\/playlist\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i;
const BARE_UUID = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;
const LIKED_PATH = /\/(?:my-collection\/tracks|liked(?:-songs|-tracks)?)(?:[/?#]|$)/i;
const MAX_TRACKS = 5000;
const SEARCH_LIMIT = 10;

function parseLink(url) {
  const trimmed = String(url || "").trim();
  if (LIKED_PATH.test(trimmed)) return {kind: "liked"};
  const match = trimmed.match(PLAYLIST_PATH) || trimmed.match(BARE_UUID);
  if (!match) throw new Error("This is not a Tidal playlist link");
  return {kind: "playlist", id: match[1].toLowerCase()};
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
      const results = (await searchSongs(settings, track)).map(toResult).filter(Boolean);
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

    async download({settings, result, directory}) {
      const tidalId = String(result?.data?.tidalId || result?.id || "").trim();
      if (!tidalId) throw new Error("This result has no Tidal track id");
      const fileName = await writeTrack(
        settings,
        directory,
        tidalId,
        result,
        (extension) => taggedFileName(result, extension) ?? `${tidalId}.${extension}`,
      );
      return {path: fileName};
    },

    async searchAlbum({settings, album}) {
      const title = String(album?.title || "").trim();
      const artist = String(album?.artist || "").trim();
      if (!title) return [];
      const payload = await subtidal(settings, "search3", {
        query: [artist, title].filter(Boolean).join(" "),
        albumCount: SEARCH_LIMIT,
        songCount: 0,
        artistCount: 0,
      });
      const results = (payload.searchResult3?.album || []).map(toAlbumResult).filter(Boolean);
      if (results.length === 0) console.warn(`no Tidal album for ${artist || "?"} - ${title}`);
      return results;
    },

    async downloadAlbum({settings, result, directory}) {
      const albumId = String(result?.data?.albumId || result?.id || "").trim();
      if (!albumId) throw new Error("This result has no Tidal album id");
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
