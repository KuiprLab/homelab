import {
  ContainerBuilder,
  MessageFlags,
  SeparatorSpacingSize,
} from "discord.js";

import type { Subcommand } from "../../feature.ts";
import { SlskdClient, SlskdError, type SlskdTransfer } from "./slskd.ts";

const MAX_LINES = 10;

const BAR_CELLS = 10;

const ACTIVE = 0x3498db;
const IDLE = 0x95a5a6;
const FAILED = 0xe74c3c;

export const status: Subcommand = {
  name: "status",
  description: "Show Soulseek downloads in progress",

  execute: async (interaction) => {
    await interaction.deferReply({ flags: MessageFlags.Ephemeral });

    try {
      const users = await SlskdClient.fromConfig().downloads();
      const files = users.flatMap((user) =>
        user.directories.flatMap((directory) =>
          directory.files.map((file) => ({ file, username: user.username })),
        ),
      );

      if (files.length === 0) {
        await interaction.editReply("Nothing queued or downloading.");
        return;
      }

      await interaction.editReply({
        components: [build(files)],
        allowedMentions: { parse: [] },
        flags: MessageFlags.IsComponentsV2,
      });
    } catch (error) {
      if (!(error instanceof SlskdError)) throw error;
      await interaction.editReply({
        content: `Soulseek is unavailable: ${error.message}`,
        allowedMentions: { parse: [] },
      });
    }
  },
};

interface Entry {
  readonly file: SlskdTransfer;
  readonly username: string;
}

function build(files: readonly Entry[]): ContainerBuilder {
  const active = files.filter(
    ({ file }) => !SlskdClient.isTransferComplete(file.state),
  );
  const failed = files.filter(({ file }) =>
    SlskdClient.isTransferFailed(file.state),
  );
  const done = files.length - active.length - failed.length;

  const shown = active.length > 0 ? active : failed;

  const container = new ContainerBuilder().setAccentColor(
    active.length > 0 ? ACTIVE : failed.length > 0 ? FAILED : IDLE,
  );

  const summary = [
    active.length > 0 ? `**${String(active.length)}** in flight` : undefined,
    done > 0 ? `${String(done)} done` : undefined,
    failed.length > 0 ? `${String(failed.length)} failed` : undefined,
  ].filter((part) => part !== undefined);

  container.addTextDisplayComponents((text) =>
    text.setContent(`## Downloads\n${summary.join(" · ")}`),
  );

  if (shown.length > 0) {
    container.addSeparatorComponents((separator) =>
      separator.setSpacing(SeparatorSpacingSize.Small),
    );

    container.addTextDisplayComponents((text) =>
      text.setContent(
        shown
          .slice(0, MAX_LINES)
          .map(({ file, username }) => describe(file, username))
          .join("\n"),
      ),
    );

    if (shown.length > MAX_LINES) {
      container.addTextDisplayComponents((text) =>
        text.setContent(`_…and ${String(shown.length - MAX_LINES)} more._`),
      );
    }
  }

  return container;
}

function describe(file: SlskdTransfer, username: string): string {
  const name = basename(file.filename);

  if (SlskdClient.isTransferFailed(file.state)) {
    const reason = file.state.replace(/^Completed, /, "").toLowerCase();
    return `${bar(0)} ${reason} · ${name} · ${username}`;
  }

  if (file.state.startsWith("Queued")) {
    return `${bar(0)} queued · ${name} · ${username}`;
  }

  const percent = Math.round(file.percentComplete);
  const mb = (file.averageSpeed / 1_000_000).toFixed(1);
  return `${bar(percent)} ${String(percent)}% · ${name} · ${mb} MB/s`;
}

function bar(percent: number): string {
  const clamped = Math.min(Math.max(percent, 0), 100);
  const filled =
    clamped >= 100 ? BAR_CELLS : Math.floor((clamped / 100) * BAR_CELLS);
  return `\`${"▰".repeat(filled)}${"▱".repeat(BAR_CELLS - filled)}\``;
}

function basename(filename: string): string {
  const parts = filename.split(/[\\/]/);
  return parts[parts.length - 1] ?? filename;
}
