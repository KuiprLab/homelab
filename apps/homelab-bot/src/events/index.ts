import type { Client } from "discord.js";

import { clientReady } from "./clientReady.ts";
import { gatewayError } from "./gatewayError.ts";
import { interactionCreate } from "./interactionCreate.ts";

export function registerEvents(client: Client): void {
  client.once(clientReady.name, clientReady.execute);
  client.on(interactionCreate.name, interactionCreate.execute);
  client.on(gatewayError.name, gatewayError.execute);
}
