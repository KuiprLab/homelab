import { Client, Events, GatewayIntentBits, MessageFlags } from "discord.js";

import { byName } from "./commands/index.ts";
import { config } from "./config.ts";

// Guilds is the only intent a slash-command bot needs. Adding MessageContent
// or GuildMembers later makes the bot privileged and requires approval from
// Discord once it is in more than 100 servers.
const client = new Client({ intents: [GatewayIntentBits.Guilds] });

client.once(Events.ClientReady, (ready) => {
  console.log(`Logged in as ${ready.user.tag} (${ready.user.id})`);
  console.log(
    `Serving ${byName.size} command(s): ${[...byName.keys()].join(", ")}`,
  );
});

client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;

  const command = byName.get(interaction.commandName);
  if (command === undefined) {
    // Discord still has a command registered that this build no longer ships.
    console.warn(`Ignoring unknown command /${interaction.commandName}`);
    return;
  }

  try {
    await command.execute(interaction);
  } catch (error) {
    console.error(`/${interaction.commandName} failed:`, error);

    // Discord closes the interaction after three seconds, so a failure that
    // arrives late has to go out as a follow-up instead of a reply.
    const body = {
      content:
        "That command failed. The details are in `journalctl -u homelab-bot`.",
      flags: MessageFlags.Ephemeral,
    } as const;

    try {
      if (interaction.replied || interaction.deferred) {
        await interaction.followUp(body);
      } else {
        await interaction.reply(body);
      }
    } catch (replyError) {
      console.error(
        "Could not report the failure back to Discord:",
        replyError,
      );
    }
  }
});

client.on(Events.Error, (error) => {
  console.error("Gateway error:", error);
});

// systemd sends SIGTERM on stop and restart. Closing the gateway connection
// makes Discord mark the bot offline immediately instead of waiting for the
// heartbeat to time out.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    console.log(`Received ${signal}, shutting down`);
    void client.destroy().finally(() => process.exit(0));
  });
}

await client.login(config.token);
