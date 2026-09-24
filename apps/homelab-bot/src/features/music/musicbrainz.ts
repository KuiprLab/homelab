import { MusicBrainzApi } from "musicbrainz-api";
import { CoverArtArchiveApi } from "musicbrainz-api";

export const mbApi = new MusicBrainzApi({
  appName: "my-app",
  appVersion: "0.1.0",
  appContactInfo: "user@mail.org",
});

const coverArtArchiveApiClient = new CoverArtArchiveApi();

/**
 * How long a cover is worth waiting for. The archive is a separate service
 * from MusicBrainz and degrades on its own schedule -- a fourteen-second
 * answer, in HTML rather than JSON, is what pushed /music find past Discord's
 * interaction window once. A card without a thumbnail beats a late card.
 */
const COVER_ART_TIMEOUT_MS = 5_000;

/**
 * The front cover for a release, when the archive has one.
 *
 * Plenty of releases have no art at all -- the archive is a separate,
 * volunteer-filled database, not part of MusicBrainz -- and it says so with a
 * 404 or with a response carrying no images. Neither is worth failing a
 * command over, so both come back as undefined and the caller renders a card
 * without a thumbnail.
 */
export async function fetchCoverArt(
  releaseMbid: string,
): Promise<string | undefined> {
  try {
    const coverInfo = await Promise.race([
      coverArtArchiveApiClient.getReleaseCovers(releaseMbid),
      timeout(COVER_ART_TIMEOUT_MS),
    ]);
    return coverInfo?.images?.[0]?.image;
  } catch (error) {
    console.warn(`No cover art for release ${releaseMbid}:`, error);
    return undefined;
  }
}

/**
 * Rejects once the budget is spent. The request it races is left to finish on
 * its own -- the archive's client takes no abort signal, and an unawaited
 * response costs nothing but the socket.
 */
function timeout(ms: number): Promise<never> {
  return new Promise((_resolve, reject) => {
    setTimeout(
      () => reject(new Error(`no answer within ${String(ms)}ms`)),
      ms,
    ).unref();
  });
}
