import { MessageFlags } from "discord.js";

import type { Subcommand } from "../../feature.ts";
import { SlskdClient, SlskdError, type SlskdTransfer } from "./slskd.ts";

/** Lines of detail before the reply is summarised instead. */
const MAX_LINES = 10;

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

      const active = files.filter(
        ({ file }) => !SlskdClient.isTransferComplete(file.state),
      );
      const failed = files.filter(({ file }) =>
        SlskdClient.isTransferFailed(file.state),
      );
      const done = files.length - active.length - failed.length;

      // Failures are only worth listing when nothing is running: while a
      // download is in flight that is the thing being asked about.
      const shown = active.length > 0 ? active : failed;
      const lines = shown
        .slice(0, MAX_LINES)
        .map(({ file, username }) => describe(file, username));

      if (shown.length > MAX_LINES) {
        lines.push(`_…and ${shown.length - MAX_LINES} more._`);
      }

      const summary = [
        active.length > 0 ? `${active.length} in flight` : undefined,
        done > 0 ? `${done} done` : undefined,
        failed.length > 0 ? `${failed.length} failed` : undefined,
      ].filter((part) => part !== undefined);

      await interaction.editReply({
        content: [`**Downloads** — ${summary.join(", ")}`, ...lines].join("\n"),
        allowedMentions: { parse: [] },
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

function describe(file: SlskdTransfer, username: string): string {
  const name = basename(file.filename);
  // A queued transfer has no speed and no progress worth printing; its state
  // ("Queued, Remotely") is the whole story until the peer starts sending.
  if (file.state.startsWith("Queued")) {
    return `\`queued\` ${name} — ${username}`;
  }

  if (SlskdClient.isTransferFailed(file.state)) {
    // "Completed, Rejected" is the peer refusing, usually because it no longer
    // has the file or will not share it with this account.
    return `\`${file.state.replace(/^Completed, /, "").toLowerCase()}\` ${name} — ${username}`;
  }

  const percent = Math.round(file.percentComplete);
  const mb = (file.averageSpeed / 1_000_000).toFixed(1);
  return `\`${percent}%\` ${name} — ${username}, ${mb} MB/s`;
}

/** Peers send Windows-style paths, so the separator is a backslash. */
function basename(filename: string): string {
  const parts = filename.split(/[\\/]/);
  return parts[parts.length - 1] ?? filename;
}
