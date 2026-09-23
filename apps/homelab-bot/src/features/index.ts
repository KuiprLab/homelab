import type { Command, Feature } from "../feature.ts";

import { diagnostics } from "./diagnostics/index.ts";

/**
 * Every feature the bot ships, listed explicitly rather than discovered by
 * scanning the directory at runtime: an explicit list is type checked, and the
 * Nix store is read-only and not somewhere to go looking for modules.
 *
 * Adding a feature is two lines -- import it, add it here.
 */
export const features: readonly Feature[] = [diagnostics];

export const commands: readonly Command[] = features.flatMap(
  (feature) => feature.commands ?? [],
);

/**
 * Slash command names are global to the application, so two features cannot
 * both own /play. Discord would silently keep whichever we sent last; fail
 * loudly at startup instead, naming both features.
 */
function indexCommands(): ReadonlyMap<string, Command> {
  const index = new Map<string, Command>();
  const owner = new Map<string, string>();

  for (const feature of features) {
    for (const command of feature.commands ?? []) {
      const name = command.data.name;
      const existing = owner.get(name);
      if (existing !== undefined) {
        throw new Error(
          `Features "${existing}" and "${feature.name}" both define /${name}. ` +
            `Command names are global to the application, so they must be ` +
            `unique across features.`,
        );
      }
      owner.set(name, feature.name);
      index.set(name, command);
    }
  }

  return index;
}

export const byName: ReadonlyMap<string, Command> = indexCommands();

/** Which feature owns a command, for log output. */
export function featureOf(commandName: string): string | undefined {
  return features.find((feature) =>
    (feature.commands ?? []).some((c) => c.data.name === commandName),
  )?.name;
}
