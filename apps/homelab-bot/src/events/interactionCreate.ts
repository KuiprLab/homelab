import {
  Events,
  MessageFlags,
  type ButtonInteraction,
  type ChatInputCommandInteraction,
  type ModalSubmitInteraction,
} from "discord.js";

import { resolve, resolveButton, resolveModal } from "../features/index.ts";
import type { Event } from "./event.ts";

export const interactionCreate: Event<typeof Events.InteractionCreate> = {
  name: Events.InteractionCreate,
  async execute(interaction) {
    if (interaction.isChatInputCommand()) return runCommand(interaction);
    if (interaction.isButton()) return runButton(interaction);
    if (interaction.isModalSubmit()) return runModal(interaction);
  },
};

async function runCommand(
  interaction: ChatInputCommandInteraction,
): Promise<void> {
  const group = interaction.options.getSubcommandGroup(false);
  const subcommand = interaction.options.getSubcommand(false);
  const path = [interaction.commandName, group, subcommand]
    .filter((part) => part !== null)
    .join(" ");

  const execute = resolve(interaction.commandName, group, subcommand);
  if (execute === undefined) {
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

async function runButton(interaction: ButtonInteraction): Promise<void> {
  const execute = resolveButton(interaction.customId);
  if (execute === undefined) {
    console.warn(`Ignoring unknown button "${interaction.customId}"`);
    return;
  }

  try {
    await execute(interaction);
  } catch (error) {
    console.error(`Button "${interaction.customId}" failed:`, error);
    await reportFailure(
      interaction,
      "That button failed. The details are in `journalctl -u homelab-bot`.",
    );
  }
}

async function runModal(interaction: ModalSubmitInteraction): Promise<void> {
  const execute = resolveModal(interaction.customId);
  if (execute === undefined) {
    console.warn(`Ignoring unknown modal "${interaction.customId}"`);
    return;
  }

  try {
    await execute(interaction);
  } catch (error) {
    console.error(`Modal "${interaction.customId}" failed:`, error);
    await reportFailure(
      interaction,
      "That form failed. The details are in `journalctl -u homelab-bot`.",
    );
  }
}

async function reportFailure(
  interaction:
    ChatInputCommandInteraction | ButtonInteraction | ModalSubmitInteraction,
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
