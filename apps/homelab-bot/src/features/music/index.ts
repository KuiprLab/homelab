import type { Command, Feature } from "../../feature.ts";

import { find } from "./find.ts";

const command: Command = {
  name: "music",
  description: "Music library and playback",
  subcommands: [find],
};

export const music: Feature = {
  name: "music",
  commands: [command],
};
