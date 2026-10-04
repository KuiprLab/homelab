import { Client, GatewayIntentBits } from "discord.js";

import { config } from "./config.ts";
import { registerEvents } from "./events/index.ts";

// Guilds is the only intent a slash-command bot needs. Adding MessageContent
// or GuildMembers later makes the bot privileged and requires approval from
// Discord once it is in more than 100 servers.
const client = new Client({ intents: [GatewayIntentBits.Guilds] });

registerEvents(client);

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
