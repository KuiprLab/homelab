import type { Command, Feature } from "../../feature.ts";

import { status } from "./status.ts";

const command: Command = {
  name: "lab",
  description: "Homelab commands",
  subcommands: [status],
};

export const lab: Feature = {
  name: "lab",
  commands: [command],
};
