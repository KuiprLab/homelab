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
import { isRetagConfigured, requestRetag, RetagError } from "./retagRequests.ts";

/** Library albums a name may match before the user has to be more specific. */
const MAX_MATCHES = 5;

/** Releases to offer. Discord caps a select menu at 25 options. */
const MAX_CANDIDATES = 25;

/** How long a pending retag choice stays valid. */
const TTL_MS = 15 * 60 * 1000;

const EXPIRED =
  "That retag has expired. Run `/music retag` again to pick from fresh results.";

/** The select inside the modal. Scoped to the modal, not routed. */
const RELEASE_SELECT = "release";

interface Pending {
  readonly album: LibraryAlbum;
  readonly candidates: readonly IReleaseMatch[];
  readonly storedAt: number;
}

/**
 * Pending choices, keyed by what the button carries.
 *
 * Same trade as searches.ts: a customId caps at 100 characters, which is not
 * enough for an album id plus twenty-five release ids, so the payload stays
 * here and the button carries a key into it. A restart or the TTL invalidates
 * an open picker, which the handler reports rather than acting on stale data.
 */
const pending = new Map<string, Pending>();

/**
 * Retag an album against a MusicBrainz release you choose.
 *
 * Worth having because beets cannot fix this itself: an album already carrying
 * a release id matches that id at distance ~0 no matter what else fits, so a
 * wrong tag anchors itself. Chaos A.D. tagged from Spotify claimed sixteen
 * tracks; Storm of the Light's Bane tagged to a 2-CD reissue claimed
 * twenty-three. Both need a release forced by hand, once.
 */
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

    // A MusicBrainz search follows, and that client is rate limited.
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    const text = interaction.options.getString("album", true).trim();

    let matches: readonly LibraryAlbum[];
    try {
      matches = findAlbums(text, MAX_MATCHES + 1);
    } catch (error) {
      if (!(error instanceof LibraryError)) throw error;
      await interaction.editReply(`Could not read the library: ${error.message}`);
      return;
    }

    if (matches.length === 0) {
      await interaction.editReply(`No album in the library matches "${text}".`);
      return;
    }

    if (matches.length > 1) {
      // Retagging rewrites tags on real files, so an ambiguous name is asked
      // about rather than guessed at.
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

/**
 * Opens the picker. showModal has to be the first response to an interaction
 * -- Discord does not allow deferring one -- so the options come from the
 * stored search rather than from a fresh MusicBrainz call.
 */
export const chooseRetagButton = defineButton({
  feature: "music",
  name: "retag",

  execute: async (interaction, key) => {
    const choice = recall(key);
    if (choice === undefined) {
      await interaction.reply({ content: EXPIRED, flags: MessageFlags.Ephemeral });
      return;
    }

    await interaction.showModal(
      retagModal
        .build(key)
        .setTitle("Choose a release")
        .addLabelComponents(
          new LabelBuilder()
            .setLabel("MusicBrainz releases")
            .setDescription(clamp(`${choice.album.album} — ${choice.album.albumartist}`, 100))
            .setStringSelectMenuComponent(
              new StringSelectMenuBuilder()
                .setCustomId(RELEASE_SELECT)
                .setPlaceholder("Pick the release to tag against")
                .addOptions(choice.candidates.map((release) => option(release))),
            ),
        ),
    );
  },
});

/** Writes the request. The importer picks it up and reports back itself. */
export const retagModal = defineModal({
  feature: "music",
  name: "retag",

  execute: async (interaction, key) => {
    const choice = recall(key);
    if (choice === undefined) {
      await interaction.reply({ content: EXPIRED, flags: MessageFlags.Ephemeral });
      return;
    }

    const [releaseId] = interaction.fields.getStringSelectValues(RELEASE_SELECT);

    // Resolved against the stored candidates, so an id that was never offered
    // cannot get through.
    const release = choice.candidates.find(
      (candidate) => candidate.id === releaseId,
    );
    if (release === undefined) {
      await interaction.reply({ content: EXPIRED, flags: MessageFlags.Ephemeral });
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
      await interaction.editReply(`Could not queue the retag: ${error.message}`);
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
  const source =
    album.source === "" ? "MusicBrainz" : album.source;

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

/**
 * Releases whose track count matches what the library holds, first. That is
 * the whole reason to retag -- a release claiming more tracks is what makes an
 * album look incomplete -- so it decides the order rather than being one more
 * column to read.
 */
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

/** "12 tracks · 1993 · XE · CD" -- everything needed to tell pressings apart. */
function describe(release: IReleaseMatch): string {
  const count = trackCount(release);
  return [
    count === undefined ? undefined : `${String(count)} tracks`,
    release.date === undefined || release.date === ""
      ? undefined
      : release.date.slice(0, 4),
    release.country,
    release.media?.map((medium) => medium.format).filter(Boolean).join("+"),
  ]
    .filter((part) => part !== undefined && part !== "")
    .join(" · ");
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

function remember(
  album: LibraryAlbum,
  candidates: readonly IReleaseMatch[],
): string {
  // base64url so the key cannot contain the ":" a customId splits on.
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

/** Inside a quoted Lucene phrase only the quote and backslash are structural. */
function escape(value: string): string {
  return value.replace(/["\\]/g, (character) => `\\${character}`);
}

/** Discord rejects an over-long label or description outright. */
function clamp(text: string, limit: number): string {
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}
