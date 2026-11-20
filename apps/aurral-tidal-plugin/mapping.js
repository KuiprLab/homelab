const UNAVAILABLE_MARKER = /\s*\(unavailable on Tidal\)$/i;
const DURATION_TOLERANCE_MS = 5000;

export const normalize = (value) =>
  String(value || "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, " ")
    .trim();

export function toTrack(entry) {
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

export function toResult(entry) {
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

export function toAlbumResult(entry) {
  const id = String(entry?.id || "").trim();
  const artist = String(entry?.artist || "").trim();
  const title = String(entry?.title || entry?.name || "").trim();
  if (!id || !artist || !title) return null;
  const year = Number(entry?.year);
  const trackCount = Number(entry?.songCount);
  return {
    id,
    title,
    artist,
    ...(Number.isFinite(year) && year > 0 && {year}),
    ...(Number.isFinite(trackCount) && trackCount > 0 && {trackCount}),
    data: {albumId: id},
  };
}

// A wrong match would star an unrelated Tidal track, so demand the same title,
// an overlapping artist, and a duration within tolerance.
export function pickId(songs, track) {
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
