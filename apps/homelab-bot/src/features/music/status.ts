import {
  ContainerBuilder,
  MessageFlags,
  SeparatorSpacingSize,
} from "discord.js";

import type { Subcommand } from "../../feature.ts";
import { SlskdClient, SlskdError, type SlskdTransfer } from "./slskd.ts";

/** Transfers to name before collapsing the rest to a count. */
const MAX_LINES = 10;

/** Cells in the progress bar. Wide enough to read, narrow enough for mobile. */
const BAR_CELLS = 10;

const ACTIVE = 0x3498db;
const IDLE = 0x95a5a6;
const FAILED = 0xe74c3c;

/**
 * What slskd is currently doing with the files /music find queued.
 *
 * Ephemeral, and read fresh on each invocation rather than pushed: a transfer
 * can sit in a peer's queue for longer than an interaction token lives, so
 * there is nothing to edit in place -- run it again instead.
 */
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

  // Failures are only worth listing when nothing is running: while a download
  // is in flight that is the thing being asked about.
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

    // One text display for the whole list rather than one per file: a message
    // may hold forty components in total, and a busy queue would blow through
    // that on its own.
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
    // "Completed, Rejected" is the peer refusing, usually because it no longer
    // has the file or will not share it with this account.
    const reason = file.state.replace(/^Completed, /, "").toLowerCase();
    return `${bar(0)} ${reason} · ${name} · ${username}`;
  }

  // A queued transfer has no speed and no progress worth printing; its state
  // is the whole story until the peer starts sending.
  if (file.state.startsWith("Queued")) {
    return `${bar(0)} queued · ${name} · ${username}`;
  }

  const percent = Math.round(file.percentComplete);
  const mb = (file.averageSpeed / 1_000_000).toFixed(1);
  return `${bar(percent)} ${String(percent)}% · ${name} · ${mb} MB/s`;
}

/**
 * A progress bar out of block characters, which render on every platform.
 *
 * Floored, not rounded: rounding shows 99% as a full bar, which reads as
 * finished when it is not.
 */
function bar(percent: number): string {
  const clamped = Math.min(Math.max(percent, 0), 100);
  const filled =
    clamped >= 100 ? BAR_CELLS : Math.floor((clamped / 100) * BAR_CELLS);
  return `\`${"▰".repeat(filled)}${"▱".repeat(BAR_CELLS - filled)}\``;
}

/** Peers send Windows-style paths, so the separator is a backslash. */
function basename(filename: string): string {
  const parts = filename.split(/[\\/]/);
  return parts[parts.length - 1] ?? filename;
}
