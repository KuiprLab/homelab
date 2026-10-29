import { DiscordAPIError, type REST, Routes } from "discord.js";

import { definitions } from "./features/index.ts";
import { config } from "./config.ts";

export function commandRoute(): `/${string}` {
  return config.guildId === null
    ? Routes.applicationCommands(config.applicationId)
    : Routes.applicationGuildCommands(config.applicationId, config.guildId);
}

interface Normalized {
  name: string;
  description: string;
  type: number;
  required: boolean;
  options: Normalized[];
}

// Discord echoes ids, versions and generated defaults back, so compare only the fields we send.
function normalize(command: Record<string, unknown>): Normalized {
  const options = Array.isArray(command["options"]) ? command["options"] : [];
  return {
    name: String(command["name"] ?? ""),
    description: String(command["description"] ?? ""),
    type: Number(command["type"] ?? 1),
    required: Boolean(command["required"] ?? false),
    options: options
      .map((option) => normalize(option as Record<string, unknown>))
      .sort((a, b) => a.name.localeCompare(b.name)),
  };
}

function fingerprint(list: readonly Record<string, unknown>[]): string {
  return JSON.stringify(
    list.map(normalize).sort((a, b) => a.name.localeCompare(b.name)),
  );
}

export type SyncResult = "unchanged" | "updated";

// Registering is a rate-limited write and dev restarts on every save, so read before writing.
export async function syncCommands(rest: REST): Promise<SyncResult> {
  const desired = definitions as unknown as Record<string, unknown>[];
  const route = commandRoute();

  const existing = (await rest.get(route)) as Record<string, unknown>[];
  if (fingerprint(existing) === fingerprint(desired)) return "unchanged";

  await rest.put(route, { body: desired });
  return "updated";
}

export function explainSyncFailure(error: unknown): string {
  if (error instanceof DiscordAPIError && error.status === 403) {
    return (
      "Discord refused with 403 Missing Access. The bot is either not in " +
      `guild ${config.guildId ?? "(global)"} or was invited without the ` +
      "applications.commands scope -- re-invite it with that scope."
    );
  }
  return String(error);
}
