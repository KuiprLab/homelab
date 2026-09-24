import {
  Events,
  MessageFlags,
  type ChatInputCommandInteraction,
} from "discord.js";

import { resolve } from "../features/index.ts";
import type { Event } from "./event.ts";

export const interactionCreate: Event<typeof Events.InteractionCreate> = {
  name: Events.InteractionCreate,
  async execute(interaction) {
    if (interaction.isChatInputCommand()) return runCommand(interaction);
  },
};

async function runCommand(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  // A command with subcommands is never invoked on its own, so the handler is
  // identified by the whole path, not just the command name.
  const group = interaction.options.getSubcommandGroup(false);
  const subcommand = interaction.options.getSubcommand(false);
  const path = [interaction.commandName, group, subcommand]
    .filter((part) => part !== null)
    .join(" ");

  const execute = resolve(interaction.commandName, group, subcommand);
  if (execute === undefined) {
    // Discord still advertises a command this build no longer answers.
    console.warn(`Ignoring unknown command /${path}`);
    return;
  }

  try {
    await execute(interaction);
  } catch (error) {
    console.error(`/${path} failed:`, error);
    await reportFailure(
      interaction,
      "That command failed. The details are in `journalctl -u homelab-bot`.",
    );
  }
}

/**
 * Discord closes the interaction after three seconds, so a failure that
 * arrives late has to go out as a follow-up instead of a reply.
 */
async function reportFailure(
  interaction: ChatInputCommandInteraction,
  content: string,
): Promise<void> {
  const body = {
    content,
    flags: MessageFlags.Ephemeral,
  } as const;

  try {
    if (interaction.replied || interaction.deferred) {
      await interaction.followUp(body);
    } else {
      await interaction.reply(body);
    }
  } catch (replyError) {
    console.error("Could not report the failure back to Discord:", replyError);
  }
}
