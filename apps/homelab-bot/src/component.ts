import {
  ButtonBuilder,
  ModalBuilder,
  type ButtonInteraction,
  type ModalSubmitInteraction,
} from "discord.js";

/** Discord's cap on a customId, both on a component and on a modal. */
const MAX_CUSTOM_ID = 100;

const ID_SEGMENT = /^[a-z0-9-]+$/;

interface Identity {
  readonly feature: string;
  readonly name: string;
}

interface Spec<Interaction> extends Identity {
  readonly execute: (interaction: Interaction, data: string) => Promise<void>;
}

export interface Handler<Interaction> extends Spec<Interaction> {
  readonly id: string;
}

export interface Button extends Handler<ButtonInteraction> {
  readonly build: (data?: string) => ButtonBuilder;
}

export interface Modal extends Handler<ModalSubmitInteraction> {
  readonly build: (data?: string) => ModalBuilder;
}

function identify(spec: Identity): {
  readonly id: string;
  readonly customId: (data: string) => string;
} {
  for (const [label, segment] of [
    ["feature", spec.feature],
    ["name", spec.name],
  ] as const) {
    if (!ID_SEGMENT.test(segment)) {
      throw new Error(
        `Component ${label} "${segment}" must be lowercase letters, digits ` +
          `or dashes. A customId is split on ":", so an id segment cannot ` +
          `contain one.`,
      );
    }
  }

  const id = `${spec.feature}:${spec.name}`;

  return {
    id,
    customId: (data) => {
      const customId = `${id}:${data}`;
      if (customId.length > MAX_CUSTOM_ID) {
        throw new Error(
          `Component ${id} was given ${data.length} characters of data, ` +
            `which makes a customId of ${customId.length}; Discord allows ` +
            `${MAX_CUSTOM_ID}. Keep the payload server-side and put a key in ` +
            `the customId instead.`,
        );
      }
      return customId;
    },
  };
}

export function defineButton(spec: Spec<ButtonInteraction>): Button {
  const { id, customId } = identify(spec);
  return {
    ...spec,
    id,
    build: (data = "") => new ButtonBuilder().setCustomId(customId(data)),
  };
}

export function defineModal(spec: Spec<ModalSubmitInteraction>): Modal {
  const { id, customId } = identify(spec);
  return {
    ...spec,
    id,
    build: (data = "") => new ModalBuilder().setCustomId(customId(data)),
  };
}

export function parseCustomId(
  customId: string,
): { readonly id: string; readonly data: string } | undefined {
  const first = customId.indexOf(":");
  if (first === -1) return undefined;
  const second = customId.indexOf(":", first + 1);
  if (second === -1) return undefined;
  return { id: customId.slice(0, second), data: customId.slice(second + 1) };
}
