/**
 * Registers this build's commands with Discord, as a one-shot.
 *
 * The bot also does this on startup. This entry point stays because it is
 * useful on its own: `systemctl start homelab-bot-register` on a host, or
 * `npm run dev:register`, to push a change without restarting the bot and to
 * see the result as a real exit status.
 */
import { REST } from "discord.js";

import { commands } from "./features/index.ts";
import { config } from "./config.ts";
import { explainSyncFailure, syncCommands } from "./register.ts";

const rest = new REST().setToken(config.token);
const names = commands.map((command) => `/${command.data.name}`).join(", ");
const where =
  config.guildId === null
    ? "globally (may take up to an hour to appear)"
    : `to guild ${config.guildId}`;

try {
  const result = await syncCommands(rest);
  console.log(
    result === "updated"
      ? `Registered ${commands.length} command(s) ${where}: ${names}`
      : `Already up to date ${where}: ${names}`,
  );
} catch (error) {
  console.error(explainSyncFailure(error));
  process.exit(1);
}
