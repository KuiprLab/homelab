import { Events } from "discord.js";

import { componentIds, features, routeNames } from "../features/index.ts";
import { explainSyncFailure, syncCommands } from "../register.ts";
import type { Event } from "./event.ts";

export const clientReady: Event<typeof Events.ClientReady> = {
  name: Events.ClientReady,
  async execute(client) {
    console.log(`Logged in as ${client.user.tag} (${client.user.id})`);
    const names = routeNames()
      .map((route) => `/${route}`)
      .join(", ");
    console.log(
      `Features: ${features.map((feature) => feature.name).join(", ")}`,
    );
    const { buttons, modals } = componentIds();
    if (buttons.length > 0) console.log(`Buttons: ${buttons.join(", ")}`);
    if (modals.length > 0) console.log(`Modals: ${modals.join(", ")}`);

    // A feature that fails to start should not take the bot down with it --
    // a broken music feature still leaves /ping answering.
    for (const feature of features) {
      if (feature.setup === undefined) continue;
      void Promise.resolve(feature.setup(client)).catch((error: unknown) => {
        console.error(`Feature "${feature.name}" failed to start:`, error);
      });
    }

    void (async () => {
      try {
        const result = await syncCommands(client.rest);
        console.log(
          result === "updated"
            ? `Registered with Discord: ${names}`
            : `Already registered with Discord: ${names}`,
        );
      } catch (error) {
        // Never fatal. A bot that cannot update its command list is still a
        // working bot for whatever is already registered, and the deployed unit
        // restarting in a loop would be a worse outcome than a stale /ping.
        console.error(
          `Could not register commands. ${explainSyncFailure(error)}`,
        );
      }
    })();
  },
};
