import type { RESTPostAPIChatInputApplicationCommandsJSONBody } from "discord.js";

import {
  routeKey,
  routesOf,
  toDefinition,
  validate,
  type Command,
  type Execute,
  type Feature,
} from "../feature.ts";
import { diagnostics } from "./diagnostics/index.ts";

/**
 * Every feature the bot ships, listed explicitly rather than discovered by
 * scanning the directory at runtime: an explicit list is type checked, and the
 * Nix store is read-only and not somewhere to go looking for modules.
 *
 * Adding a feature is two lines -- import it, add it here.
 */
export const features: readonly Feature[] = [diagnostics];

interface Registered {
  readonly command: Command;
  readonly feature: string;
  readonly routes: ReadonlyMap<string, Execute>;
}

/**
 * Slash command names are global to the application, so two features cannot
 * both own /play. Discord would silently keep whichever we sent last; fail
 * loudly at startup instead, naming both features.
 */
function build(): ReadonlyMap<string, Registered> {
  const registry = new Map<string, Registered>();

  for (const feature of features) {
    for (const command of feature.commands ?? []) {
      const existing = registry.get(command.name);
      if (existing !== undefined) {
        throw new Error(
          `Features "${existing.feature}" and "${feature.name}" both define ` +
            `/${command.name}. Command names are global to the application, ` +
            `so they must be unique across features.`,
        );
      }
      validate(command, feature.name);
      registry.set(command.name, {
        command,
        feature: feature.name,
        routes: routesOf(command),
      });
    }
  }

  return registry;
}

const registry = build();

/** What gets sent to Discord. Derived from the same declarations as the routes. */
export const definitions: readonly RESTPostAPIChatInputApplicationCommandsJSONBody[] =
  [...registry.values()].map((entry) => toDefinition(entry.command));

/** Every route the bot answers, as Discord would name it: "ping", "music play". */
export function routeNames(): string[] {
  return [...registry.values()].flatMap((entry) =>
    [...entry.routes.keys()].map((route) =>
      route === "" ? entry.command.name : `${entry.command.name} ${route}`,
    ),
  );
}

/** Resolve a running interaction to its handler, subcommands included. */
export function resolve(
  commandName: string,
  group: string | null,
  subcommand: string | null,
): Execute | undefined {
  return registry.get(commandName)?.routes.get(routeKey(group, subcommand));
}
