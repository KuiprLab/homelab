import {
  SlashCommandBuilder,
  type ChatInputCommandInteraction,
} from "discord.js";

export const data = new SlashCommandBuilder()
  .setName("ping")
  .setDescription("Check that the bot is alive and how fast it is responding");

export async function execute(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  // interaction.createdTimestamp is when Discord received the command, so this
  // measures the whole round trip rather than just our own handler.
  const roundtrip = Date.now() - interaction.createdTimestamp;
  const gateway = Math.round(interaction.client.ws.ping);

  await interaction.reply(
    `Pong. Round trip ${roundtrip}ms, gateway ${gateway < 0 ? "still measuring" : `${gateway}ms`}.`,
  );
}
