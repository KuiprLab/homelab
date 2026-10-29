import {
  ButtonStyle,
  ContainerBuilder,
  MessageFlags,
  SectionBuilder,
} from "discord.js";

import type { Subcommand } from "../../feature.ts";
import { completeAlbumButton } from "./find.ts";
import {
  incompleteAlbums,
  isLibraryConfigured,
  LibraryError,
  type IncompleteAlbum,
} from "./library.ts";

const MAX_SHOWN = 5;

export const missing: Subcommand = {
  name: "missing",
  description: "List albums the library only has part of",

  execute: async (interaction) => {
    if (!isLibraryConfigured()) {
      await interaction.reply({
        content:
          "The beets library is not configured, so I cannot tell what is " +
          "missing. Set `BEETS_LIBRARY`.",
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    try {
      const albums = incompleteAlbums(MAX_SHOWN + 1);

      if (albums.length === 0) {
        await interaction.reply({
          content:
            "Nothing is missing. Every album is as complete as its tags claim.",
          flags: MessageFlags.Ephemeral,
        });
        return;
      }

      await interaction.reply({
        components: [build(albums)],
        allowedMentions: { parse: [] },
        flags: MessageFlags.IsComponentsV2 | MessageFlags.Ephemeral,
      });
    } catch (error) {
      if (!(error instanceof LibraryError)) throw error;
      await interaction.reply({
        content: `Could not read the beets library: ${error.message}`,
        flags: MessageFlags.Ephemeral,
      });
    }
  },
};

function build(albums: readonly IncompleteAlbum[]): ContainerBuilder {
  const container = new ContainerBuilder().setAccentColor(0xe67e22);
  const shown = albums.slice(0, MAX_SHOWN);

  container.addTextDisplayComponents((text) =>
    text.setContent(`## Incomplete albums\n${summary(albums)}`),
  );

  for (const album of shown) {
    const line =
      `**${album.album}** — ${album.albumartist}\n` +
      `${String(album.have)} of ${String(album.expect)} tracks`;

    if (album.discs > album.discsPresent) {
      container.addTextDisplayComponents((text) =>
        text.setContent(
          `${line} · _disc ${String(album.discsPresent + 1)} of ` +
            `${String(album.discs)} was never imported — retag if you do ` +
            `not want that edition_`,
        ),
      );
      continue;
    }

    if (album.releaseId === undefined) {
      container.addTextDisplayComponents((text) =>
        text.setContent(`${line} · _no MusicBrainz id, so nothing to look up_`),
      );
      continue;
    }

    container.addSectionComponents(
      new SectionBuilder()
        .addTextDisplayComponents((text) => text.setContent(line))
        .setButtonAccessory(
          completeAlbumButton
            .build(album.releaseId)
            .setLabel("Complete")
            .setStyle(ButtonStyle.Primary),
        ),
    );
  }

  return container;
}

function summary(albums: readonly IncompleteAlbum[]): string {
  if (albums.length <= MAX_SHOWN) {
    return `${albums.length} album${albums.length === 1 ? "" : "s"} short of their tracklist.`;
  }
  return `Showing ${String(MAX_SHOWN)}, worst first. There are more.`;
}
