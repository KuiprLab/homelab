import type { Command, Feature } from "../../feature.ts";

import {
  chooseReleaseButton,
  downloadButton,
  find,
  pickReleaseModal,
} from "./find.ts";

const command: Command = {
  name: "music",
  description: "Music library commands",
  subcommands: [find],
};

export const music: Feature = {
  name: "music",
  commands: [command],
  buttons: [downloadButton, chooseReleaseButton],
  modals: [pickReleaseModal],
};
