import { Client, GatewayIntentBits } from "discord.js";

import { config } from "./config.ts";
import { registerEvents } from "./events/index.ts";

const client = new Client({ intents: [GatewayIntentBits.Guilds] });

registerEvents(client);

for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.once(signal, () => {
    console.log(`Received ${signal}, shutting down`);
    void client.destroy().finally(() => process.exit(0));
  });
}

await client.login(config.token);
