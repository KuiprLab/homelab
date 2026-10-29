import { randomBytes } from "node:crypto";

import {
  ButtonStyle,
  ContainerBuilder,
  LabelBuilder,
  MessageFlags,
  SectionBuilder,
  StringSelectMenuBuilder,
  StringSelectMenuOptionBuilder,
} from "discord.js";
import type { IRelease, IReleaseList, IReleaseMatch } from "musicbrainz-api";

import { defineButton, defineModal } from "../../component.ts";
import type { Subcommand } from "../../feature.ts";
import {
  findAlbums,
  isLibraryConfigured,
  LibraryError,
  type LibraryAlbum,
} from "./library.ts";
import { mbApi } from "./musicbrainz.ts";
import {
  isRetagConfigured,
  requestRetag,
  RetagError,
} from "./retagRequests.ts";

const MAX_MATCHES = 5;

/** Releases to offer. Discord caps a select menu at 25 options. */
const MAX_CANDIDATES = 25;

const TTL_MS = 15 * 60 * 1000;

const EXPIRED =
  "That retag has expired. Run `/music retag` again to pick from fresh results.";

const RELEASE_SELECT = "release";

interface Pending {
  readonly album: LibraryAlbum;
  readonly candidates: readonly IReleaseMatch[];
  readonly storedAt: number;
}

const pending = new Map<string, Pending>();

export const retag: Subcommand = {
  name: "retag",
  description: "Retag an album against a MusicBrainz release you pick",

  options: (builder) =>
    builder.addStringOption((option) =>
      option
        .setName("album")
        .setDescription("Album in the library, or 'artist album'")
        .setRequired(true)
        .setMinLength(2)
        .setMaxLength(100),
    ),

  execute: async (interaction) => {
    if (!isLibraryConfigured() || !isRetagConfigured()) {
      await interaction.reply({
        content:
          "Retagging needs both `BEETS_LIBRARY` and `BEETS_RETAG_DIR`, and " +
          "one of them is not set.",
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    const text = interaction.options.getString("album", true).trim();

    let matches: readonly LibraryAlbum[];
    try {
      matches = findAlbums(text, MAX_MATCHES + 1);
    } catch (error) {
      if (!(error instanceof LibraryError)) throw error;
      await interaction.editReply(
        `Could not read the library: ${error.message}`,
      );
      return;
    }

    if (matches.length === 0) {
      await interaction.editReply(`No album in the library matches "${text}".`);
      return;
    }

    if (matches.length > 1) {
      await interaction.editReply({
        content:
          `"${text}" matches ${String(matches.length)} albums:\n` +
          matches
            .slice(0, MAX_MATCHES)
            .map((album) => `• ${album.albumartist} — ${album.album}`)
            .join("\n") +
          "\nBe more specific.",
        allowedMentions: { parse: [] },
      });
      return;
    }

    const album = matches[0]!;
    const results: IReleaseList = await mbApi.search("release", {
      query: `release:"${escape(album.album)}" AND artist:"${escape(album.albumartist)}"`,
      limit: MAX_CANDIDATES,
    });

    const candidates = rank(results.releases, album.tracks);

    if (candidates.length === 0) {
      await interaction.editReply(
        `MusicBrainz has no releases for **${album.album}** by ` +
          `**${album.albumartist}**.`,
      );
      return;
    }

    const key = remember(album, candidates);

    await interaction.editReply({
      components: [card(album, candidates, key)],
      allowedMentions: { parse: [] },
      flags: MessageFlags.IsComponentsV2,
    });
  },
};

export const chooseRetagButton = defineButton({
  feature: "music",
  name: "retag",

  execute: async (interaction, key) => {
    const choice = recall(key);
    if (choice === undefined) {
      await interaction.reply({
        content: EXPIRED,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    await interaction.showModal(
      retagModal
        .build(key)
        .setTitle("Choose a release")
        .addLabelComponents(
          new LabelBuilder()
            .setLabel("MusicBrainz releases")
            .setDescription(
              clamp(`${choice.album.album} — ${choice.album.albumartist}`, 100),
            )
            .setStringSelectMenuComponent(
              new StringSelectMenuBuilder()
                .setCustomId(RELEASE_SELECT)
                .setPlaceholder("Pick the release to tag against")
                .addOptions(
                  choice.candidates.map((release) => option(release)),
                ),
            ),
        ),
    );
  },
});

export const retagModal = defineModal({
  feature: "music",
  name: "retag",

  execute: async (interaction, key) => {
    const choice = recall(key);
    if (choice === undefined) {
      await interaction.reply({
        content: EXPIRED,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    const [releaseId] =
      interaction.fields.getStringSelectValues(RELEASE_SELECT);

    const release = choice.candidates.find(
      (candidate) => candidate.id === releaseId,
    );
    if (release === undefined) {
      await interaction.reply({
        content: EXPIRED,
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    try {
      await requestRetag({
        albumId: choice.album.id,
        releaseId: release.id,
        label: `${choice.album.albumartist} — ${choice.album.album}`,
      });
    } catch (error) {
      if (!(error instanceof RetagError)) throw error;
      await interaction.editReply(
        `Could not queue the retag: ${error.message}`,
      );
      return;
    }

    pending.delete(key);

    await interaction.editReply({
      content:
        `Queued a retag of **${choice.album.album}** against ` +
        `${describe(release)}.\nThe importer applies it and reports back.`,
      allowedMentions: { parse: [] },
    });
  },
});

function card(
  album: LibraryAlbum,
  candidates: readonly IReleaseMatch[],
  key: string,
): ContainerBuilder {
  const source = album.source === "" ? "MusicBrainz" : album.source;

  return new ContainerBuilder()
    .setAccentColor(0x9b59b6)
    .addSectionComponents(
      new SectionBuilder()
        .addTextDisplayComponents((text) =>
          text.setContent(
            `## ${album.album}\n${album.albumartist}\n` +
              `${String(album.tracks)} files in the library · tagged from ` +
              `${source}\n` +
              `Current id: \`${album.currentId === "" ? "none" : album.currentId}\``,
          ),
        )
        .setButtonAccessory(
          chooseRetagButton
            .build(key)
            .setLabel("Choose release")
            .setStyle(ButtonStyle.Primary),
        ),
    )
    .addTextDisplayComponents((text) =>
      text.setContent(
        `_${String(candidates.length)} MusicBrainz releases found; the ones ` +
          `matching your ${String(album.tracks)} files come first._`,
      ),
    );
}

function rank(
  releases: readonly IReleaseMatch[],
  tracks: number,
): readonly IReleaseMatch[] {
  return [...releases]
    .sort(
      (a, b) =>
        Number(trackCount(b) === tracks) - Number(trackCount(a) === tracks) ||
        Math.abs((trackCount(a) ?? 0) - tracks) -
          Math.abs((trackCount(b) ?? 0) - tracks),
    )
    .slice(0, MAX_CANDIDATES);
}

function option(release: IReleaseMatch): StringSelectMenuOptionBuilder {
  return new StringSelectMenuOptionBuilder()
    .setLabel(clamp(describe(release), 100))
    .setDescription(clamp(release.title, 100))
    .setValue(release.id);
}

function describe(release: IReleaseMatch): string {
  const count = trackCount(release);
  return [
    count === undefined ? undefined : `${String(count)} tracks`,
    release.date === undefined || release.date === ""
      ? undefined
      : release.date.slice(0, 4),
    release.country,
    release.media
      ?.map((medium) => medium.format)
      .filter(Boolean)
      .join("+"),
  ]
    .filter((part) => part !== undefined && part !== "")
    .join(" · ");
}

function trackCount(release: IRelease): number | undefined {
  if (release["track-count"] !== undefined) return release["track-count"];
  const total =
    release.media?.reduce((sum, medium) => sum + medium["track-count"], 0) ?? 0;
  return total > 0 ? total : undefined;
}

function remember(
  album: LibraryAlbum,
  candidates: readonly IReleaseMatch[],
): string {
  const key = randomBytes(6).toString("base64url");
  pending.set(key, { album, candidates, storedAt: Date.now() });
  return key;
}

function recall(key: string): Pending | undefined {
  const choice = pending.get(key);
  if (choice === undefined) return undefined;
  if (Date.now() - choice.storedAt > TTL_MS) {
    pending.delete(key);
    return undefined;
  }
  return choice;
}

function escape(value: string): string {
  return value.replace(/["\\]/g, (character) => `\\${character}`);
}

function clamp(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}
