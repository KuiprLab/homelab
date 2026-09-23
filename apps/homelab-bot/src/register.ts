import { DiscordAPIError, type REST, Routes } from "discord.js";

import { commands } from "./features/index.ts";
import { config } from "./config.ts";

/**
 * Guild-scoped commands appear instantly; global ones can take an hour to
 * propagate. Which one we use is decided entirely by DISCORD_GUILD_ID.
 */
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

/**
 * Reduce a command -- ours or Discord's -- to the fields we actually set.
 *
 * Discord echoes back ids, versions and defaulted fields we never sent, so the
 * two sides are never equal as-is. Defaults are applied explicitly here (type
 * 1 is CHAT_INPUT) so an unchanged command compares equal and we can skip the
 * write.
 */
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

/**
 * Make Discord's command list match this build's.
 *
 * Reads before writing: registering is a rate-limited write, and `npm run dev`
 * restarts on every save, so an unconditional PUT would mean a write per
 * keystroke-ish. A GET is cheap and the common case is "nothing changed".
 */
export async function syncCommands(rest: REST): Promise<SyncResult> {
  const desired = commands.map(
    (command) => command.data.toJSON() as Record<string, unknown>,
  );
  const route = commandRoute();

  const existing = (await rest.get(route)) as Record<string, unknown>[];
  if (fingerprint(existing) === fingerprint(desired)) return "unchanged";

  await rest.put(route, { body: desired });
  return "updated";
}

/** A human-readable reason, for the cases that are actually actionable. */
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
