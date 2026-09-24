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
import { fetchCoverArt, mbApi } from "./musicbrainz.ts";
import { recallSearch, rememberSearch } from "./searches.ts";

/** How many releases a search offers to pick between. */
const SEARCH_LIMIT = 5;

/** Discord cap. Well above SEARCH_LIMIT, but the picker is built from a list. */
const MAX_SELECT_OPTIONS = 25;

/** Shown when the table no longer holds the search a click refers to. */
const EXPIRED =
  "That search has expired. Run `/music find` again to pick from fresh results.";

export const find: Subcommand = {
  name: "find",
  description: "Search the music library",

  options: (builder) =>
    builder.addStringOption((option) =>
      option
        .setName("query")
        .setDescription("Artist, album or track to look for")
        .setRequired(true)
        // Discord enforces these itself, so a junk query is rejected in the
        // client before it ever reaches us.
        .setMinLength(2)
        .setMaxLength(100),
    ),

  execute: async (interaction) => {
    const query = interaction.options.getString("query", true).trim();

    const albums: IReleaseList = await mbApi.search("release", {
      query: query,
      limit: SEARCH_LIMIT,
    });

    if (albums.count === 0 || albums.releases.length < 1) {
      await interaction.reply({
        content: "Error no albums found for query: " + query,
        allowedMentions: { parse: [] },
      });
      return;
    }

    const album: IReleaseMatch = albums.releases[0]!;

    // A picker is only worth offering -- and only worth remembering the
    // search for -- when there is something else to pick.
    const key =
      albums.releases.length > 1
        ? rememberSearch(query, albums.releases)
        : undefined;

    await interaction.reply({
      components: [await buildMessageForRelease(album, key)],
      allowedMentions: { parse: [] },
      flags: MessageFlags.IsComponentsV2,
      ephemeral: true,
    });
  },
};

export const downloadButton = defineButton({
  feature: "music",
  name: "download",

  execute: async (interaction, releaseId) => {
    // Two MusicBrainz round trips follow and that client is rate limited, so
    // claim the interaction first: Discord discards the token after three
    // seconds and a reply that arrives late fails with "Unknown interaction".
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    // artist-credits and media: a lookup does not carry what a search result
    // carries by default, but these two fill in artist and track count.
    const release = await mbApi.lookup("release", releaseId, [
      "artist-credits",
      "media",
    ]);

    await interaction.editReply({
      components: [await buildMessageForRelease(release)],
      allowedMentions: { parse: [] },
      flags: MessageFlags.IsComponentsV2,
    });
  },
});

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
  const cover = (await fetchCoverArt(release.id)) ?? "";
  const artistCredit = artistOf(release);

  const section1 = new SectionBuilder()
    .addTextDisplayComponents((textDisplay) =>
      textDisplay.setContent(
        `## ${release.title} by ${artistCredit}\n` +
          `Released: ${release.date ?? "Unknown"}\n` +
          `Track Count: ${trackCount(release) ?? "Unknown"}\n`,
      ),
    )
    .setThumbnailAccessory((thumbnail) =>
      thumbnail
        .setDescription("alt text displaying on the image")
        .setURL(cover),
    );

  return new ContainerBuilder()
    .setAccentColor(0x0099ff)
    .addSectionComponents(section1)
    .addActionRowComponents((actionRow) =>
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
