/**
 * Pushes the command definitions to Discord.
 *
 * This is a separate entry point, not part of bot startup: registering is a
 * write against Discord's API that is rate limited and only needs to happen
 * when the command list actually changes. Run it by hand after adding or
 * changing a command:
 *
 *   systemctl start homelab-bot-register
 */
import { REST, Routes } from "discord.js";

import { commands } from "./commands/index.ts";
import { config } from "./config.ts";

const body = commands.map((command) => command.data.toJSON());
const rest = new REST().setToken(config.token);

const route =
  config.guildId === null
    ? Routes.applicationCommands(config.applicationId)
    : Routes.applicationGuildCommands(config.applicationId, config.guildId);

await rest.put(route, { body });

console.log(
  `Registered ${body.length} command(s) ${
    config.guildId === null
      ? "globally (may take up to an hour)"
      : `to guild ${config.guildId}`
  }: ${commands.map((c) => `/${c.data.name}`).join(", ")}`,
);
