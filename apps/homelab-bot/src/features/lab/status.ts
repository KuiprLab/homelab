import { MessageFlags } from "discord.js";

import type { Subcommand } from "../../feature.ts";
import { checks, GatusError, type Check } from "./gatus.ts";

/**
 * How many healthy checks to name before collapsing the group to a count.
 * Failures are always listed in full -- they are the reason to run this.
 */
const MAX_HEALTHY_LISTED = 4;

/**
 * What gatus currently thinks of the lab.
 *
 * The pull side of monitoring on purpose: gatus already pushes its own alerts
 * to Discord when something breaks, and what that cannot answer is "is it
 * broken right now", asked from a phone.
 */
export const status: Subcommand = {
  name: "status",
  description: "Show what gatus currently thinks of the lab",

  execute: async (interaction) => {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    try {
      const all = await checks();

      if (all.length === 0) {
        await interaction.editReply("gatus is watching nothing yet.");
        return;
      }

      const down = all.filter((check) => !check.up);
      const header =
        down.length === 0
          ? `✅ All ${all.length} checks passing.`
          : `❌ ${down.length} of ${all.length} checks failing.`;

      await interaction.editReply({
        content: [header, "", ...describeGroups(all)].join("\n"),
        allowedMentions: { parse: [] },
      });
    } catch (error) {
      if (!(error instanceof GatusError)) throw error;
      await interaction.editReply({
        content: `gatus is unavailable: ${error.message}`,
        allowedMentions: { parse: [] },
      });
    }
  },
};

/** One block per gatus group, failures first within each. */
function describeGroups(all: readonly Check[]): string[] {
  const groups = new Map<string, Check[]>();
  for (const check of all) {
    const group = groups.get(check.group);
    if (group === undefined) groups.set(check.group, [check]);
    else group.push(check);
  }

  return [...groups.entries()].flatMap(([name, members]) => {
    const down = members.filter((check) => !check.up);
    const up = members.filter((check) => check.up);

    const lines = down.map(
      (check) => `❌ ${check.name} — last checked ${ago(check.at)}`,
    );

    // A wall of green is noise; the count is the useful part, unless there
    // are few enough that naming them costs nothing.
    if (up.length > MAX_HEALTHY_LISTED) {
      lines.push(`✅ ${up.length} others passing`);
    } else {
      lines.push(
        ...up.map((check) => `✅ ${check.name} — ${check.responseMs}ms`),
      );
    }

    return [`**${name}**`, ...lines, ""];
  });
}

/** gatus probes on its own schedule, so a stale result is worth spotting. */
function ago(at: Date): string {
  const seconds = Math.round((Date.now() - at.getTime()) / 1000);
  if (seconds < 90) return `${seconds}s ago`;
  const minutes = Math.round(seconds / 60);
  return minutes < 90 ? `${minutes}m ago` : `${Math.round(minutes / 60)}h ago`;
}
