import type { Awaitable, ClientEvents } from "discord.js";

/**
 * One gateway event: the guide's `{ name, once, execute }` shape, minus
 * `once`, which the registration site decides. The generic pins `name` to a
 * single event and ties `execute`'s arguments to that event's actual
 * signature -- a `Client<true>` for ClientReady, an `Interaction` for
 * InteractionCreate.
 */
export interface Event<K extends keyof ClientEvents = keyof ClientEvents> {
  readonly name: K;
  readonly execute: (...args: ClientEvents[K]) => Awaitable<void>;
}
