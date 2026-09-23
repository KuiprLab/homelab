import { MusicBrainzApi } from "musicbrainz-api";
import { CoverArtArchiveApi } from "musicbrainz-api";

export const mbApi = new MusicBrainzApi({
  appName: "my-app",
  appVersion: "0.1.0",
  appContactInfo: "user@mail.org",
});

const coverArtArchiveApiClient = new CoverArtArchiveApi();

export async function fetchCoverArt(
  releaseMbid: string,
): Promise<string | undefined> {
  const coverInfo =
    await coverArtArchiveApiClient.getReleaseCovers(releaseMbid);
  return coverInfo.images[0]?.image;
}
