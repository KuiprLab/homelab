import type { ChatInputCommandInteraction } from "discord.js";

import type { Command } from "../../feature.ts";

export const ping: Command = {
  name: "ping",
  description: "Check that the bot is alive and how fast it is responding",

  async execute(interaction: ChatInputCommandInteraction): Promise<void> {
    // createdTimestamp is when Discord received the command, so this measures
    // the whole round trip rather than just our own handler.
    const roundtrip = Date.now() - interaction.createdTimestamp;
    const gateway = Math.round(interaction.client.ws.ping);

    await interaction.reply(
      `Pong. Round trip ${roundtrip}ms, gateway ` +
        `${gateway < 0 ? "still measuring" : `${gateway}ms`}.`,
    );
  },
};
