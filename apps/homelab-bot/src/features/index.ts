import type { RESTPostAPIChatInputApplicationCommandsJSONBody } from "discord.js";

import { parseCustomId, type Handler } from "../component.ts";
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
import { music } from "./music/index.ts";

/**
 * Every feature the bot ships, listed explicitly rather than discovered by
 * scanning the directory at runtime: an explicit list is type checked, and the
 * Nix store is read-only and not somewhere to go looking for modules.
 *
 * Adding a feature is two lines -- import it, add it here.
 */
export const features: readonly Feature[] = [diagnostics, music];

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

/**
 * Buttons and modals are keyed by their whole id, the same way commands are
 * keyed by name: ids are global to the application, so two features cannot
 * both own "music:download". A feature may only register components declaring
 * its own name, or a customId would advertise a feature that does not answer
 * it.
 */
function buildRegistry<
  T extends { readonly id: string; readonly feature: string },
>(
  kind: string,
  componentsOf: (feature: Feature) => readonly T[] | undefined,
): ReadonlyMap<string, T> {
  const components = new Map<string, T>();

  for (const feature of features) {
    for (const component of componentsOf(feature) ?? []) {
      if (component.feature !== feature.name) {
        throw new Error(
          `Feature "${feature.name}" registers ${kind} ${component.id}, ` +
            `which declares itself part of "${component.feature}". The first ` +
            `segment of an id must be the feature that registers it.`,
        );
      }
      if (components.has(component.id)) {
        throw new Error(
          `Feature "${feature.name}" registers ${kind} ${component.id} ` +
            `twice. Ids are global to the application, like command names.`,
        );
      }
      components.set(component.id, component);
    }
  }

  return components;
}

/**
 * Turn a registry into a lookup that takes a running interaction's customId
 * and hands back its handler with the customId's data already bound.
 */
function resolver<Interaction>(
  registry: ReadonlyMap<string, Handler<Interaction>>,
): (
  customId: string,
) => ((interaction: Interaction) => Promise<void>) | undefined {
  return (customId) => {
    const parsed = parseCustomId(customId);
    if (parsed === undefined) return undefined;
    const component = registry.get(parsed.id);
    if (component === undefined) return undefined;
    return (interaction) => component.execute(interaction, parsed.data);
  };
}

const buttonRegistry = buildRegistry("button", (feature) => feature.buttons);
const modalRegistry = buildRegistry("modal", (feature) => feature.modals);

/** Every button and modal the bot answers, as their customIds name them. */
export function componentIds(): { buttons: string[]; modals: string[] } {
  return {
    buttons: [...buttonRegistry.keys()],
    modals: [...modalRegistry.keys()],
  };
}

export const resolveButton = resolver(buttonRegistry);
export const resolveModal = resolver(modalRegistry);
