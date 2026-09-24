import { MusicBrainzApi } from "musicbrainz-api";
import { CoverArtArchiveApi } from "musicbrainz-api";

export const mbApi = new MusicBrainzApi({
  appName: "my-app",
  appVersion: "0.1.0",
  appContactInfo: "user@mail.org",
});

const coverArtArchiveApiClient = new CoverArtArchiveApi();

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
    const coverInfo =
      await coverArtArchiveApiClient.getReleaseCovers(releaseMbid);
    return coverInfo?.images?.[0]?.image;
  } catch (error) {
    console.warn(`No cover art for release ${releaseMbid}:`, error);
    return undefined;
  }
}
