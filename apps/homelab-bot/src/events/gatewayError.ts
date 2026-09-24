import { Events } from "discord.js";

import type { Event } from "./event.ts";

export const gatewayError: Event<typeof Events.Error> = {
  name: Events.Error,
  execute(error) {
    console.error("Gateway error:", error);
  },
};
