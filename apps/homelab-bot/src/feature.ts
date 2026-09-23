import type { ChatInputCommandInteraction, Client } from "discord.js";

export interface Command {
  readonly data: {
    readonly name: string;
    toJSON(): unknown;
  };
  execute(interaction: ChatInputCommandInteraction): Promise<void>;
}

/**
 * A feature is a slice of the bot organised by what it is for -- music,
 * management, diagnostics -- rather than by what kind of thing it contains.
 *
 * Everything a feature needs lives in its own directory, so adding one never
 * means editing three shared files, and deleting one means deleting a
 * directory.
 */
export interface Feature {
  /** Used in log output and to point at the offender when two features clash. */
  readonly name: string;

  readonly commands?: readonly Command[];

  /**
   * Run once, after the client is connected. For anything a feature needs
   * beyond slash commands: event listeners, timers, voice connections.
   *
   * Throwing here is not fatal to the bot -- see the caller in index.ts.
   */
  readonly setup?: (client: Client<true>) => void | Promise<void>;
}
