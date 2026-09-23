import {
  SlashCommandBuilder,
  type ChatInputCommandInteraction,
  type Client,
  type RESTPostAPIChatInputApplicationCommandsJSONBody,
  type SlashCommandSubcommandBuilder,
} from "discord.js";

export type Execute = (
  interaction: ChatInputCommandInteraction,
) => Promise<void>;

/**
 * One leaf of a command: `/music play`.
 *
 * Its description and options live next to its handler deliberately. The
 * alternative -- building the parent's schema in one place and switching on
 * subcommand names in another -- lets the two drift, and the failure is a
 * command Discord advertises that the bot does not answer.
 */
export interface Subcommand {
  readonly name: string;
  readonly description: string;
  readonly options?: (
    builder: SlashCommandSubcommandBuilder,
  ) => SlashCommandSubcommandBuilder;
  readonly execute: Execute;
}

/** `/music queue add`, `/music queue clear`. Discord nests exactly this deep. */
export interface SubcommandGroup {
  readonly name: string;
  readonly description: string;
  readonly subcommands: readonly Subcommand[];
}

/**
 * A top-level command. Either it does something itself (`execute`), or it
 * routes to subcommands -- Discord does not allow both, because a parent with
 * subcommands is not invokable on its own.
 */
export interface Command {
  readonly name: string;
  readonly description: string;
  readonly options?: (builder: SlashCommandBuilder) => SlashCommandBuilder;
  readonly execute?: Execute;
  readonly subcommands?: readonly Subcommand[];
  readonly groups?: readonly SubcommandGroup[];
}

export interface Feature {
  readonly name: string;
  readonly commands?: readonly Command[];
  readonly setup?: (client: Client<true>) => void | Promise<void>;
}

/** Discord's cap, per command and per group. */
const MAX_SUBCOMMANDS = 25;

function describeSubcommand(
  builder: SlashCommandSubcommandBuilder,
  subcommand: Subcommand,
): SlashCommandSubcommandBuilder {
  const described = builder
    .setName(subcommand.name)
    .setDescription(subcommand.description);
  return subcommand.options?.(described) ?? described;
}

/**
 * Build the schema Discord receives from the same declaration the router
 * dispatches on, so the two cannot disagree.
 */
export function toDefinition(
  command: Command,
): RESTPostAPIChatInputApplicationCommandsJSONBody {
  const builder = new SlashCommandBuilder()
    .setName(command.name)
    .setDescription(command.description);

  if (command.options !== undefined) command.options(builder);

  for (const subcommand of command.subcommands ?? []) {
    builder.addSubcommand((sub) => describeSubcommand(sub, subcommand));
  }

  for (const group of command.groups ?? []) {
    builder.addSubcommandGroup((builderGroup) => {
      builderGroup.setName(group.name).setDescription(group.description);
      for (const subcommand of group.subcommands) {
        builderGroup.addSubcommand((sub) =>
          describeSubcommand(sub, subcommand),
        );
      }
      return builderGroup;
    });
  }

  return builder.toJSON();
}

/**
 * The key a running interaction resolves to: "" for a plain command, "play"
 * for a subcommand, "queue add" for a grouped one.
 */
export function routeKey(
  group: string | null,
  subcommand: string | null,
): string {
  if (subcommand === null) return "";
  return group === null ? subcommand : `${group} ${subcommand}`;
}

/** Every route a command answers, keyed as routeKey describes. */
export function routesOf(command: Command): ReadonlyMap<string, Execute> {
  const routes = new Map<string, Execute>();

  if (command.execute !== undefined) routes.set("", command.execute);
  for (const subcommand of command.subcommands ?? []) {
    routes.set(subcommand.name, subcommand.execute);
  }
  for (const group of command.groups ?? []) {
    for (const subcommand of group.subcommands) {
      routes.set(`${group.name} ${subcommand.name}`, subcommand.execute);
    }
  }

  return routes;
}

/** Fail at startup rather than shipping a command Discord will reject. */
export function validate(command: Command, feature: string): void {
  const where = `feature "${feature}", command /${command.name}`;
  const subcommandCount =
    (command.subcommands?.length ?? 0) + (command.groups?.length ?? 0);
  const hasChildren = subcommandCount > 0;

  if (hasChildren && command.execute !== undefined) {
    throw new Error(
      `${where} has both an execute and subcommands. Discord does not let a ` +
        `parent command be invoked on its own, so its execute could never run.`,
    );
  }
  if (!hasChildren && command.execute === undefined) {
    throw new Error(`${where} has neither an execute nor any subcommands.`);
  }
  if (hasChildren && command.options !== undefined) {
    throw new Error(
      `${where} has both options and subcommands. Discord allows only one; ` +
        `put the options on the individual subcommands.`,
    );
  }
  if (subcommandCount > MAX_SUBCOMMANDS) {
    throw new Error(
      `${where} declares ${subcommandCount} subcommands and groups; ` +
        `Discord allows ${MAX_SUBCOMMANDS}.`,
    );
  }
  for (const group of command.groups ?? []) {
    if (group.subcommands.length > MAX_SUBCOMMANDS) {
      throw new Error(
        `${where}, group ${group.name} declares ` +
          `${group.subcommands.length} subcommands; Discord allows ${MAX_SUBCOMMANDS}.`,
      );
    }
  }
}
