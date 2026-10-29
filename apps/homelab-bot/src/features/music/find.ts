import {
  ButtonStyle,
  ContainerBuilder,
  LabelBuilder,
  MessageFlags,
  SectionBuilder,
  StringSelectMenuBuilder,
  StringSelectMenuOptionBuilder,
  type ButtonBuilder,
  type ButtonInteraction,
} from "discord.js";
import type { IRelease, IReleaseList, IReleaseMatch } from "musicbrainz-api";

import { defineButton, defineModal } from "../../component.ts";
import type { Subcommand } from "../../feature.ts";
import { rememberImportHint, remoteDirectoryOf } from "./hints.ts";
import { fetchCoverArt, mbApi } from "./musicbrainz.ts";
import { recallSearch, rememberSearch } from "./searches.ts";
import { SlskdClient, SlskdError, type SlskdFile } from "./slskd.ts";

const SEARCH_LIMIT = 5;

/** Discord cap. Well above SEARCH_LIMIT, but the picker is built from a list. */
const MAX_SELECT_OPTIONS = 25;

const SLSKD_RESPONSE_LIMIT = 20;

const MAX_ENQUEUE_ATTEMPTS = 3;

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

function releaseQuery(album: string, artist?: string): string {
  const terms = [`release:"${escapeLucene(album)}"`];
  if (artist !== undefined && artist !== "") {
    terms.push(`artist:"${escapeLucene(artist)}"`);
  }
  return terms.join(" AND ");
}

function escapeLucene(value: string): string {
  return value.replace(/["\\]/g, (character) => `\\${character}`);
}

function describeQuery(album: string, artist?: string): string {
  return artist === undefined || artist === ""
    ? album
    : `${album} by ${artist}`;
}

export const downloadButton = defineButton({
  feature: "music",
  name: "download",

  execute: (interaction, releaseId) =>
    queueRelease(interaction, releaseId, { complete: false }),
});

export const completeAlbumButton = defineButton({
  feature: "music",
  name: "complete",

  execute: (interaction, releaseId) =>
    queueRelease(interaction, releaseId, { complete: true }),
});

async function queueRelease(
  interaction: ButtonInteraction,
  releaseId: string,
  { complete }: { complete: boolean },
): Promise<void> {
  await interaction.deferReply();

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

    // Filenames go over verbatim: the peer matches on its own path and size.
    const queued = await slskd.enqueueFirstAccepted(
      peers.slice(0, MAX_ENQUEUE_ATTEMPTS).map((peer) => ({
        username: peer.username,
        files: peer.files.map(({ filename, size }) => ({ filename, size })),
      })),
    );

    const from = peers.find((peer) => peer.username === queued.username);

    const directory = remoteDirectoryOf(from?.files[0]?.filename ?? "");
    if (directory !== undefined) {
      await rememberImportHint({
        directory,
        releaseId: release.id,
        title: release.title,
        artist: artistOf(release),
        complete,
      });
    }

    await interaction.editReply({
      content:
        `Queued ${queued.fileCount} FLAC files for **${release.title}** ` +
        `by ${artistOf(release)} from ` +
        `${from === undefined ? queued.username : describe(from)}` +
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
}

interface PeerAlbum {
  readonly username: string;
  readonly hasFreeUploadSlot: boolean;
  readonly uploadSpeed: number;
  readonly queueLength: number;
  readonly directory: string;
  readonly files: readonly SlskdFile[];
}

async function findFlac(
  slskd: SlskdClient,
  release: IRelease,
): Promise<{ peers: readonly PeerAlbum[]; timedOut: boolean }> {
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
    { directory: string; files: SlskdFile[]; score: number } | undefined;
  for (const [directory, group] of groups) {
    // Only the leaf segment counts: the artist folder above can match the title.
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

function directoryOf(filename: string): string {
  const separator = Math.max(
    filename.lastIndexOf("\\"),
    filename.lastIndexOf("/"),
  );
  return separator === -1 ? "" : filename.slice(0, separator);
}

function normalise(value: string): string {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, "");
}

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

const RELEASE_SELECT = "release";

export const pickReleaseModal = defineModal({
  feature: "music",
  name: "pick",

  execute: async (interaction, key) => {
    const [releaseId] =
      interaction.fields.getStringSelectValues(RELEASE_SELECT);

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
      await interaction.reply({
        components: [await buildMessageForRelease(release, key)],
        allowedMentions: { parse: [] },
        flags: MessageFlags.IsComponentsV2 | MessageFlags.Ephemeral,
      });
      return;
    }

    await interaction.deferUpdate();
    await interaction.editReply({
      components: [await buildMessageForRelease(release, key)],
      allowedMentions: { parse: [] },
      flags: MessageFlags.IsComponentsV2,
    });
  },
});

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
    // A thumbnail with an empty URL is rejected by Discord, reply and all.
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

function trackCount(release: IRelease): number | undefined {
  if (release["track-count"] !== undefined) return release["track-count"];
  const total =
    release.media?.reduce((sum, medium) => sum + medium["track-count"], 0) ?? 0;
  return total > 0 ? total : undefined;
}

function clamp(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}
