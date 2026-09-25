import {
  ContainerBuilder,
  MessageFlags,
  SeparatorSpacingSize,
} from "discord.js";

import type { Subcommand } from "../../feature.ts";
import { checks, GatusError, type Check } from "./gatus.ts";

/** Green while everything passes, red the moment anything does not. */
const HEALTHY = 0x2ecc71;
const FAILING = 0xe74c3c;

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

      await interaction.editReply({
        components: [build(all)],
        allowedMentions: { parse: [] },
        flags: MessageFlags.IsComponentsV2,
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

function build(all: readonly Check[]): ContainerBuilder {
  const down = all.filter((check) => !check.up);

  const container = new ContainerBuilder().setAccentColor(
    down.length === 0 ? HEALTHY : FAILING,
  );

  container.addTextDisplayComponents((text) =>
    text.setContent(
      `## Lab status\n` +
        (down.length === 0
          ? `All **${String(all.length)}** checks passing.`
          : `**${String(down.length)}** of ${String(all.length)} checks failing.`),
    ),
  );

  // Failures first and on their own, so the thing that is wrong is not
  // something you have to find inside a list of groups.
  if (down.length > 0) {
    container.addSeparatorComponents((separator) =>
      separator.setSpacing(SeparatorSpacingSize.Small),
    );
    container.addTextDisplayComponents((text) =>
      text.setContent(
        down
          .map(
            (check) =>
              `🔴 **${check.name}** · ${check.group} · ${ago(check.at)}`,
          )
          .join("\n"),
      ),
    );
  }

  for (const [group, members] of byGroup(all)) {
    container.addSeparatorComponents((separator) =>
      separator.setSpacing(SeparatorSpacingSize.Small).setDivider(false),
    );
    container.addTextDisplayComponents((text) =>
      text.setContent(
        `**${group}**\n` +
          members
            .map(
              (check) =>
                `${check.up ? "🟢" : "🔴"} ${check.name} · ${String(check.responseMs)}ms`,
            )
            .join("\n"),
      ),
    );
  }

  return container;
}

function byGroup(all: readonly Check[]): ReadonlyMap<string, Check[]> {
  const groups = new Map<string, Check[]>();
  for (const check of all) {
    const group = groups.get(check.group);
    if (group === undefined) groups.set(check.group, [check]);
    else group.push(check);
  }
  return groups;
}

/** gatus probes on its own schedule, so a stale result is worth spotting. */
function ago(at: Date): string {
  const seconds = Math.round((Date.now() - at.getTime()) / 1000);
  if (seconds < 90) return `${String(seconds)}s ago`;
  const minutes = Math.round(seconds / 60);
  return minutes < 90
    ? `${String(minutes)}m ago`
    : `${String(Math.round(minutes / 60))}h ago`;
}
