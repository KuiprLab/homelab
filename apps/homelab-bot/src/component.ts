import {
  ButtonBuilder,
  ModalBuilder,
  type ButtonInteraction,
  type ModalSubmitInteraction,
} from "discord.js";

/** Discord's cap on a customId, both on a component and on a modal. */
const MAX_CUSTOM_ID = 100;

/** An id is "<feature>:<name>"; a customId is that plus ":<data>". */
const ID_SEGMENT = /^[a-z0-9-]+$/;

interface Identity {
  readonly feature: string;
  readonly name: string;
}

interface Spec<Interaction> extends Identity {
  readonly execute: (interaction: Interaction, data: string) => Promise<void>;
}

/**
 * Anything the registry can route to: a stable id, the feature that owns it,
 * and a handler taking the data its customId carried.
 */
export interface Handler<Interaction> extends Spec<Interaction> {
  /** "music:download". Unique across the bot, like a command name. */
  readonly id: string;
}

/**
 * A button, declared once.
 *
 * `build` and `execute` come from the same declaration on purpose: a customId
 * written at the render site and matched again at the handler is two strings
 * that can drift, and the failure that invites is a button Discord happily
 * renders that the bot then ignores. Here the customId is spelled nowhere --
 * it is derived from the id both sides already share.
 */
export interface Button extends Handler<ButtonInteraction> {
  /**
   * Render it. `data` is replayed verbatim on the click, so it carries the
   * button's subject -- a MusicBrainz id, say -- with no server-side state:
   * a click still resolves after the bot has restarted.
   */
  readonly build: (data?: string) => ButtonBuilder;
}

/** A modal, declared the same way. `execute` runs on submit. */
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
        // Discord rejects the whole message, so the component's own bug would
        // surface as the surrounding reply failing. Name it here instead.
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

/**
 * Split a customId back into the id the registry keys on and the data it was
 * built with. The data may itself contain ":" -- only the first two
 * separators are structural.
 */
export function parseCustomId(
  customId: string,
): { readonly id: string; readonly data: string } | undefined {
  const first = customId.indexOf(":");
  if (first === -1) return undefined;
  const second = customId.indexOf(":", first + 1);
  if (second === -1) return undefined;
  return { id: customId.slice(0, second), data: customId.slice(second + 1) };
}
