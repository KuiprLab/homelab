import {
  ButtonStyle,
  ContainerBuilder,
  LabelBuilder,
  MessageFlags,
  SectionBuilder,
  StringSelectMenuBuilder,
  StringSelectMenuOptionBuilder,
  type ButtonBuilder,
} from "discord.js";
import type { IRelease, IReleaseList, IReleaseMatch } from "musicbrainz-api";

import { defineButton, defineModal } from "../../component.ts";
import type { Subcommand } from "../../feature.ts";
import { rememberImportHint, remoteDirectoryOf } from "./hints.ts";
import { fetchCoverArt, mbApi } from "./musicbrainz.ts";
import { recallSearch, rememberSearch } from "./searches.ts";
import { SlskdClient, SlskdError, type SlskdFile } from "./slskd.ts";

/** How many releases a search offers to pick between. */
const SEARCH_LIMIT = 5;

/** Discord cap. Well above SEARCH_LIMIT, but the picker is built from a list. */
const MAX_SELECT_OPTIONS = 25;

/** Peers to let answer a Soulseek search before slskd stops collecting. */
const SLSKD_RESPONSE_LIMIT = 20;

/**
 * Peers to try queueing from before giving up. Each refusal costs a few
 * seconds of verification, so this trades a slower failure for a better
 * chance that a click produces an actual download.
 */
const MAX_ENQUEUE_ATTEMPTS = 3;

/** Shown when the table no longer holds the search a click refers to. */
const EXPIRED =
  "That search has expired. Run `/music find` again to pick from fresh results.";

export const find: Subcommand = {
  name: "find",
  description: "Search the music library",

  options: (builder) =>
    builder
      .addStringOption((option) =>
        option
          .setName("album")
          .setDescription("Album or release title")
          .setRequired(true)
          // Discord enforces these itself, so a junk query is rejected in the
          // client before it ever reaches us.
          .setMinLength(2)
          .setMaxLength(100),
      )
      .addStringOption((option) =>
        option
          .setName("artist")
          .setDescription("Narrows the search, and sorts out a shared title")
          .setRequired(false)
          .setMinLength(2)
          .setMaxLength(100),
      ),

  execute: async (interaction) => {
    // A MusicBrainz search and then a cover-art lookup stand between here and
    // the reply, and Discord discards the token after three seconds -- the
    // cover-art archive alone has been seen taking fourteen. Claim the
    // interaction first; everything below answers with editReply.
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    const album = interaction.options.getString("album", true).trim();
    const artist = interaction.options.getString("artist")?.trim();
    const wanted = describeQuery(album, artist);

    const results: IReleaseList = await mbApi.search("release", {
      query: releaseQuery(album, artist),
      limit: SEARCH_LIMIT,
    });

    if (results.count === 0 || results.releases.length < 1) {
      await interaction.editReply({
        content: `No releases found for **${wanted}**.`,
        allowedMentions: { parse: [] },
      });
      return;
    }

    const release: IReleaseMatch = results.releases[0]!;

    // A picker is only worth offering -- and only worth remembering the
    // search for -- when there is something else to pick.
    const key =
      results.releases.length > 1
        ? rememberSearch(wanted, results.releases)
        : undefined;

    await interaction.editReply({
      components: [await buildMessageForRelease(release, key)],
      allowedMentions: { parse: [] },
      flags: MessageFlags.IsComponentsV2,
    });
  },
};

/**
 * A fielded MusicBrainz query rather than one free-text blob.
 *
 * Searching "release" for "Cannibal Corpse Tomb of the Mutilated" scores every
 * word against every field, so an artist name matches album titles and back
 * again. Naming the fields means the artist narrows the search instead of
 * widening it, which is the whole reason the two are separate options.
 */
function releaseQuery(album: string, artist?: string): string {
  const terms = [`release:"${escapeLucene(album)}"`];
  if (artist !== undefined && artist !== "") {
    terms.push(`artist:"${escapeLucene(artist)}"`);
  }
  return terms.join(" AND ");
}

/**
 * Inside a quoted phrase only the quote and the backslash are structural --
 * the rest of Lucene's special characters are literal there. Without this a
 * title like 'Symphonies of Sickness "Remastered"' ends the phrase early and
 * MusicBrainz answers with a syntax error.
 */
function escapeLucene(value: string): string {
  return value.replace(/["\\]/g, (character) => `\\${character}`);
}

/**
 * What the user asked for. Plain text on purpose: it is stored with the search
 * and rendered into the picker's modal, which shows markdown literally rather
 * than formatting it.
 */
function describeQuery(album: string, artist?: string): string {
  return artist === undefined || artist === ""
    ? album
    : `${album} by ${artist}`;
}

export const downloadButton = defineButton({
  feature: "music",
  name: "download",

  execute: async (interaction, releaseId) => {
    // A MusicBrainz lookup and then a Soulseek search follow, and the search
    // alone runs for tens of seconds, so claim the interaction first: Discord
    // discards the token after three seconds and a reply that arrives late
    // fails with "Unknown interaction".
    await interaction.deferReply();

    // artist-credits and media: a lookup does not carry what a search result
    // carries by default, but these two fill in artist and track count.
    const release = await mbApi.lookup("release", releaseId, [
      "artist-credits",
      "media",
    ]);

    try {
      const slskd = SlskdClient.fromConfig();
      const { peers, timedOut } = await findFlac(slskd, release);

      if (peers.length === 0) {
        await interaction.editReply({
          content:
            `No FLAC found on Soulseek for **${release.title}** by ` +
            `${artistOf(release)}.` +
            (timedOut ? " The search was still running when it gave up." : ""),
          allowedMentions: { parse: [] },
        });
        return;
      }

      // Files go over verbatim -- the peer matches on its own filename and
      // size, and a normalised path is refused by the peer rather than by
      // slskd, so it would fail silently as a transfer that never starts.
      const queued = await slskd.enqueueFirstAccepted(
        peers.slice(0, MAX_ENQUEUE_ATTEMPTS).map((peer) => ({
          username: peer.username,
          files: peer.files.map(({ filename, size }) => ({ filename, size })),
        })),
      );

      const from = peers.find((peer) => peer.username === queued.username);

      // Tell the import side which release this is meant to be, before
      // the download finishes and beets has only the folder name to go
      // on. Keyed by the peer directory slskd will name the download
      // after; see hints.ts.
      const directory = remoteDirectoryOf(from?.files[0]?.filename ?? "");
      if (directory !== undefined) {
        await rememberImportHint({
          directory,
          releaseId: release.id,
          title: release.title,
          artist: artistOf(release),
        });
      }

      // Accepted, which is not the same as downloading: the files now sit
      // in the peer's queue. /music status follows them from here.
      await interaction.editReply({
        content:
          `Queued ${queued.fileCount} FLAC files for **${release.title}** ` +
          `by ${artistOf(release)} from ${from === undefined ? queued.username : describe(from)}` +
          (queued.rejected.length > 0
            ? `\n${queued.rejected.length} earlier ` +
              `${queued.rejected.length === 1 ? "peer" : "peers"} turned it down.`
            : ""),
        allowedMentions: { parse: [] },
      });
    } catch (error) {
      if (!(error instanceof SlskdError)) throw error;
      await interaction.editReply({
        content: `Soulseek is unavailable: ${error.message}`,
        allowedMentions: { parse: [] },
      });
    }
  },
});

/**
 * One peer's offer of this release: the files from a single directory of
 * theirs, not everything they answered with.
 */
interface PeerAlbum {
  readonly username: string;
  readonly hasFreeUploadSlot: boolean;
  readonly uploadSpeed: number;
  readonly queueLength: number;
  /** The peer's full directory path, kept for the log line. */
  readonly directory: string;
  readonly files: readonly SlskdFile[];
}

/**
 * Peers offering this release as FLAC, best first. "Best" is a free upload
 * slot before raw speed: a fast peer behind a long queue starts later than a
 * slow one that starts now.
 */
async function findFlac(
  slskd: SlskdClient,
  release: IRelease,
): Promise<{ peers: readonly PeerAlbum[]; timedOut: boolean }> {
  // "flac" in the search text only filters on the peer's own path naming, so
  // it narrows the network traffic without being trustworthy; isFlac below is
  // what actually decides.
  const { responses, timedOut } = await slskd.search(
    `${artistOf(release)} ${release.title} flac`,
    {
      responseLimit: SLSKD_RESPONSE_LIMIT,
      minimumResponseFileCount: trackCount(release) ?? 1,
    },
  );

  const peers = responses
    .flatMap((peer) => {
      const album = bestDirectory(peer.files.filter(isFlac), release);
      return album === undefined ? [] : [{ ...peer, ...album }];
    })
    .sort(
      (a, b) =>
        Number(b.hasFreeUploadSlot) - Number(a.hasFreeUploadSlot) ||
        b.uploadSpeed - a.uploadSpeed,
    );

  return { peers, timedOut };
}

/**
 * Pick the one directory of a peer's that actually holds this release.
 *
 * A search response is everything in that peer's library matching the query,
 * spread across their whole collection -- a hit on a soundtrack compilation,
 * another on a box set, the album itself, and the band's other albums whose
 * tags mention the artist. Queueing the lot downloads a discography when one
 * album was asked for.
 *
 * The directory whose name contains the album title wins; among equals, the
 * one whose file count is closest to the release's track count.
 */
function bestDirectory(
  files: readonly SlskdFile[],
  release: IRelease,
): { directory: string; files: readonly SlskdFile[] } | undefined {
  const groups = new Map<string, SlskdFile[]>();
  for (const file of files) {
    const directory = directoryOf(file.filename);
    const group = groups.get(directory);
    if (group === undefined) groups.set(directory, [file]);
    else group.push(file);
  }

  const wanted = normalise(release.title);
  const tracks = trackCount(release);

  let best:
    | { directory: string; files: SlskdFile[]; score: number }
    | undefined;
  for (const [directory, group] of groups) {
    // Named after the album beats any amount of file-count agreement: a
    // compilation holding one track of it is still the wrong directory.
    //
    // Only the last segment counts. Matching the whole path would score
    // "...\\Rage Against the Machine\\1996 - Evil Empire" as a hit for the
    // self-titled album, on the strength of the artist folder above it.
    const leaf = directory.split(/[\\/]/).pop() ?? directory;
    const named = normalise(leaf).includes(wanted) ? 1000 : 0;
    const closeness =
      tracks === undefined ? group.length : -Math.abs(group.length - tracks);
    const score = named + closeness;

    if (best === undefined || score > best.score) {
      best = { directory, files: group, score };
    }
  }

  return best === undefined
    ? undefined
    : { directory: best.directory, files: best.files };
}

/** Everything up to the last separator. Peers send Windows-style paths. */
function directoryOf(filename: string): string {
  const separator = Math.max(
    filename.lastIndexOf("\\"),
    filename.lastIndexOf("/"),
  );
  return separator === -1 ? "" : filename.slice(0, separator);
}

/**
 * For comparing a peer's folder name against an album title: case, spacing
 * and punctuation all vary ("Evil Empire", "evil_empire", "Evil-Empire").
 */
function normalise(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

/**
 * extension is optional and plenty of peers leave it out, so the filename is
 * the fallback -- it and size are the only fields reliably present.
 */
function isFlac(file: SlskdFile): boolean {
  return (
    file.extension?.toLowerCase().replace(/^\./, "") === "flac" ||
    file.filename.toLowerCase().endsWith(".flac")
  );
}

function describe(peer: PeerAlbum): string {
  const mb = (peer.uploadSpeed / 1_000_000).toFixed(1);
  const slot = peer.hasFreeUploadSlot
    ? "a free slot"
    : `queue ${peer.queueLength}`;
  return `**${peer.username}** (${mb} MB/s, ${slot})`;
}

/** The select inside the picker modal. Scoped to the modal, not routed. */
const RELEASE_SELECT = "release";

/**
 * Swaps the card for whichever release was picked, in place, so the message
 * stays a single card rather than growing a reply per attempt. The new card
 * carries the same search key, so the picker can be reopened to change the
 * choice again.
 */
export const pickReleaseModal = defineModal({
  feature: "music",
  name: "pick",

  execute: async (interaction, key) => {
    const [releaseId] =
      interaction.fields.getStringSelectValues(RELEASE_SELECT);

    // The picker is rendered from the stored search, so the pick is resolved
    // against it too: no second MusicBrainz call, and an id that is not one
    // of the offered releases cannot get through.
    const release = recallSearch(key)?.releases.find(
      (candidate) => candidate.id === releaseId,
    );

    if (release === undefined) {
      await interaction.reply({
        content: EXPIRED,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    if (!interaction.isFromMessage()) {
      // Only a modal opened from a message component can edit that message.
      await interaction.reply({
        components: [await buildMessageForRelease(release, key)],
        allowedMentions: { parse: [] },
        flags: MessageFlags.IsComponentsV2 | MessageFlags.Ephemeral,
      });
      return;
    }

    // Cover art is a network round trip, so claim the interaction first.
    await interaction.deferUpdate();
    await interaction.editReply({
      components: [await buildMessageForRelease(release, key)],
      allowedMentions: { parse: [] },
      flags: MessageFlags.IsComponentsV2,
    });
  },
});

/**
 * Opens the picker. Its data is the search key and the release on screen, so
 * the modal can offer the *other* results; see pickerData.
 */
export const chooseReleaseButton = defineButton({
  feature: "music",
  name: "choose",

  execute: async (interaction, data) => {
    const { key, currentId } = readPickerData(data);
    const search = recallSearch(key);

    if (search === undefined) {
      await interaction.reply({
        content: EXPIRED,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    const others = search.releases.filter(
      (release) => release.id !== currentId,
    );

    if (others.length === 0) {
      await interaction.reply({
        content: `That search only turned up this one release.`,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    // showModal has to be the first response -- Discord does not allow
    // deferring a modal -- so everything it renders comes from the stored
    // search rather than from a fresh MusicBrainz call.
    await interaction.showModal(
      pickReleaseModal
        .build(key)
        .setTitle("Choose a release")
        .addLabelComponents(
          new LabelBuilder()
            .setLabel("Other matches")
            .setDescription(clamp(`Results for "${search.query}"`, 100))
            .setStringSelectMenuComponent(
              new StringSelectMenuBuilder()
                .setCustomId(RELEASE_SELECT)
                .setPlaceholder("Pick a release")
                .addOptions(others.slice(0, MAX_SELECT_OPTIONS).map(toOption)),
            ),
        ),
    );
  },
});

function toOption(release: IReleaseMatch): StringSelectMenuOptionBuilder {
  const detail = [artistOf(release), release.date, countryOf(release)]
    .filter((part) => part !== undefined && part !== "")
    .join(" · ");

  return new StringSelectMenuOptionBuilder()
    .setLabel(clamp(release.title, 100))
    .setDescription(clamp(detail, 100))
    .setValue(release.id);
}

/**
 * The picker button's data: which search, and which release is on screen, so
 * the modal can leave the current one out. The data half of a customId may
 * contain ":", so the two pack together without escaping.
 */
function pickerData(key: string, currentId: string): string {
  return `${key}:${currentId}`;
}

function readPickerData(data: string): { key: string; currentId: string } {
  const separator = data.indexOf(":");
  if (separator === -1) return { key: data, currentId: "" };
  return {
    key: data.slice(0, separator),
    currentId: data.slice(separator + 1),
  };
}

async function buildMessageForRelease(
  release: IRelease,
  searchKey?: string,
): Promise<ContainerBuilder> {
  const cover = await fetchCoverArt(release.id);

  const summary =
    `## ${release.title} by ${artistOf(release)}\n` +
    `Released: ${release.date ?? "Unknown"}\n` +
    `Track Count: ${trackCount(release) ?? "Unknown"}\n`;

  const container = new ContainerBuilder().setAccentColor(0x0099ff);

  if (cover === undefined) {
    // A Section exists to hang an accessory off, and with no cover art there
    // is nothing to hang: a thumbnail with an empty URL is rejected by
    // Discord outright, taking the whole reply with it.
    container.addTextDisplayComponents((textDisplay) =>
      textDisplay.setContent(summary),
    );
  } else {
    container.addSectionComponents(
      new SectionBuilder()
        .addTextDisplayComponents((textDisplay) =>
          textDisplay.setContent(summary),
        )
        .setThumbnailAccessory((thumbnail) =>
          thumbnail
            .setDescription(clamp(`Cover art for ${release.title}`, 1024))
            .setURL(cover),
        ),
    );
  }

  return container.addActionRowComponents((actionRow) =>
    actionRow.setComponents(buttonsFor(release, searchKey)),
  );
}

/** The picker only appears on a card that came from a remembered search. */
function buttonsFor(release: IRelease, searchKey?: string): ButtonBuilder[] {
  const buttons = [
    downloadButton
      .build(release.id)
      .setLabel("Download")
      .setStyle(ButtonStyle.Primary),
  ];

  if (searchKey !== undefined) {
    buttons.push(
      chooseReleaseButton
        .build(pickerData(searchKey, release.id))
        .setLabel("Other releases")
        .setStyle(ButtonStyle.Secondary),
    );
  }

  return buttons;
}

function artistOf(release: IRelease): string {
  return (
    release["artist-credit"]?.map((credit) => credit.name).join(", ") ??
    "Unknown"
  );
}

function countryOf(release: IRelease): string | undefined {
  return release.country ?? undefined;
}

/**
 * Search results carry a top-level track count; the lookup endpoint only
 * exposes one per medium, so total the media when it is missing.
 */
function trackCount(release: IRelease): number | undefined {
  if (release["track-count"] !== undefined) return release["track-count"];
  const total =
    release.media?.reduce((sum, medium) => sum + medium["track-count"], 0) ?? 0;
  return total > 0 ? total : undefined;
}

/** Discord rejects an over-long label or description outright. */
function clamp(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}
