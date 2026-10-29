// One-shot push of this build's commands, without restarting the bot.
import { REST } from "discord.js";

import { definitions, routeNames } from "./features/index.ts";
import { config } from "./config.ts";
import { explainSyncFailure, syncCommands } from "./register.ts";

const rest = new REST().setToken(config.token);
const names = routeNames()
  .map((route) => `/${route}`)
  .join(", ");
const where =
  config.guildId === null
    ? "globally (may take up to an hour to appear)"
    : `to guild ${config.guildId}`;

try {
  const result = await syncCommands(rest);
  console.log(
    result === "updated"
      ? `Registered ${definitions.length} command(s) ${where}: ${names}`
      : `Already up to date ${where}: ${names}`,
  );
} catch (error) {
  console.error(explainSyncFailure(error));
  process.exit(1);
}
