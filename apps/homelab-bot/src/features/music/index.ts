import type { Command, Feature } from "../../feature.ts";

import {
  chooseReleaseButton,
  completeAlbumButton,
  downloadButton,
  find,
  pickReleaseModal,
} from "./find.ts";
import { missing } from "./missing.ts";
import { chooseRetagButton, retag, retagModal } from "./retag.ts";
import { status } from "./status.ts";

const command: Command = {
  name: "music",
  description: "Music library commands",
  subcommands: [find, missing, retag, status],
};

export const music: Feature = {
  name: "music",
  commands: [command],
  buttons: [
    downloadButton,
    chooseReleaseButton,
    completeAlbumButton,
    chooseRetagButton,
  ],
  modals: [pickReleaseModal, retagModal],
};
