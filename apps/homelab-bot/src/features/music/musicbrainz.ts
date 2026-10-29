import { MusicBrainzApi } from "musicbrainz-api";
import { CoverArtArchiveApi } from "musicbrainz-api";

export const mbApi = new MusicBrainzApi({
  appName: "my-app",
  appVersion: "0.1.0",
  appContactInfo: "user@mail.org",
});

const coverArtArchiveApiClient = new CoverArtArchiveApi();

// The cover archive degrades on its own schedule; a late answer once blew Discord's window.
const COVER_ART_TIMEOUT_MS = 5_000;

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

function timeout(ms: number): Promise<never> {
  return new Promise((_resolve, reject) => {
    setTimeout(
      () => reject(new Error(`no answer within ${String(ms)}ms`)),
      ms,
    ).unref();
  });
}
