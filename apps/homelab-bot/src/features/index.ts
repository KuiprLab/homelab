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
import { lab } from "./lab/index.ts";
import { music } from "./music/index.ts";

export const features: readonly Feature[] = [diagnostics, lab, music];

interface Registered {
  readonly command: Command;
  readonly feature: string;
  readonly routes: ReadonlyMap<string, Execute>;
}

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

export const definitions: readonly RESTPostAPIChatInputApplicationCommandsJSONBody[] =
  [...registry.values()].map((entry) => toDefinition(entry.command));

export function routeNames(): string[] {
  return [...registry.values()].flatMap((entry) =>
    [...entry.routes.keys()].map((route) =>
      route === "" ? entry.command.name : `${entry.command.name} ${route}`,
    ),
  );
}

export function resolve(
  commandName: string,
  group: string | null,
  subcommand: string | null,
): Execute | undefined {
  return registry.get(commandName)?.routes.get(routeKey(group, subcommand));
}

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

export function componentIds(): { buttons: string[]; modals: string[] } {
  return {
    buttons: [...buttonRegistry.keys()],
    modals: [...modalRegistry.keys()],
  };
}

export const resolveButton = resolver(buttonRegistry);
export const resolveModal = resolver(modalRegistry);
