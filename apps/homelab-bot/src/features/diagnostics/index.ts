import type { Feature } from "../../feature.ts";

import { ping } from "./ping.ts";

export const diagnostics: Feature = {
  name: "diagnostics",
  commands: [ping],
};
