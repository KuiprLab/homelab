import { MessageFlags, escapeMarkdown } from "discord.js";

import type { Subcommand } from "../../feature.ts";

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

    if (query.length === 0) {
      await interaction.reply({
        content: "Give me something to search for.",
        flags: MessageFlags.Ephemeral,
      });
      return;
    }

    // TODO: search Navidrome. Its Subsonic API lives at
    // https://music.int.kuipr.de/rest/search3 and is reachable without an
    // authelia session -- /rest/* is exempted in services/music/default.nix
    // precisely so subsonic clients can authenticate on their own.
    //
    // Whatever goes here should deferReply() first: Discord closes an
    // interaction after three seconds and a library search will not always
    // beat that.
    await interaction.reply({
      // Echoing user input back into a message is how an @everyone ends up
      // sent by the bot. escapeMarkdown stops it rendering as formatting;
      // allowedMentions stops it pinging anyone regardless of what it says.
      content: `Would search for \`${escapeMarkdown(query)}\` — no library is wired up yet.`,
      allowedMentions: { parse: [] },
    });
  },
};
