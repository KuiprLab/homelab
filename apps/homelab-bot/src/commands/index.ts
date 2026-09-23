import type { ChatInputCommandInteraction } from "discord.js";

import * as ping from "./ping.js";

export interface Command {
  readonly data: {
    readonly name: string;
    toJSON(): unknown;
  };
  execute(interaction: ChatInputCommandInteraction): Promise<void>;
}

/**
 * Commands are listed explicitly rather than discovered by scanning a
 * directory at runtime. Most discord.js examples glob the filesystem, which
 * costs the type checking that catches a malformed command before it ships,
 * and assumes a writable layout the Nix store does not provide.
 *
 * Adding a command is two lines: import it, add it here.
 */
export const commands: readonly Command[] = [ping];

export const byName: ReadonlyMap<string, Command> = new Map(
  commands.map((command) => [command.data.name, command]),
);
