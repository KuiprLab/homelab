import type { Client } from "discord.js";

import { clientReady } from "./clientReady.ts";
import { gatewayError } from "./gatewayError.ts";
import { interactionCreate } from "./interactionCreate.ts";

/**
 * Wire every event onto the client, listed explicitly here rather than
 * discovered by scanning the directory at runtime: an explicit list is type
 * checked, and the Nix store is read-only and not somewhere to go looking for
 * modules.
 *
 * Adding an event is two lines -- create the file, register it here.
 */
export function registerEvents(client: Client): void {
  client.once(clientReady.name, clientReady.execute);
  client.on(interactionCreate.name, interactionCreate.execute);
  client.on(gatewayError.name, gatewayError.execute);
}
