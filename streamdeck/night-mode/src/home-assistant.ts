import streamDeck from "@elgato/streamdeck";

const logger = streamDeck.logger.createScope("home-assistant");

type CompressedState = { s?: string };

type EntitiesEvent = {
	a?: Record<string, CompressedState>;
	c?: Record<string, { "+"?: CompressedState }>;
	r?: string[];
};

type Message =
	| { type: "auth_required" | "auth_ok" }
	| { type: "auth_invalid"; message: string }
	| { type: "result"; id: number; success: boolean; error?: { message: string } }
	| { type: "event"; id: number; event: EntitiesEvent };

/**
 * Follows one entity's state over Home Assistant's WebSocket API, reconnecting with backoff.
 * `subscribe_entities` sends the current state first, then only changes, and needs no admin rights.
 */
export function watchEntity(baseUrl: string, token: string, entityId: string, onState: (state: string) => void): void {
	const url = new URL("/api/websocket", baseUrl);
	url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
	let retryMs = 1_000;

	const connect = (): void => {
		const ws = new WebSocket(url);

		ws.onmessage = (e) => {
			const msg = JSON.parse(String(e.data)) as Message;
			switch (msg.type) {
				case "auth_required":
					ws.send(JSON.stringify({ type: "auth", access_token: token }));
					break;
				case "auth_ok":
					retryMs = 1_000;
					logger.info(`connected to ${url.host}`);
					ws.send(JSON.stringify({ id: 1, type: "subscribe_entities", entity_ids: [entityId] }));
					break;
				case "auth_invalid":
					logger.error(`authentication failed: ${msg.message}`);
					retryMs = 60_000;
					ws.close();
					break;
				case "result":
					if (!msg.success) logger.error(`subscribe failed: ${msg.error?.message}`);
					break;
				case "event": {
					const state = msg.event.a?.[entityId]?.s ?? msg.event.c?.[entityId]?.["+"]?.s;
					if (state !== undefined) onState(state);
					break;
				}
			}
		};

		ws.onclose = () => {
			logger.warn(`disconnected; retrying in ${retryMs / 1000}s`);
			setTimeout(connect, retryMs);
			retryMs = Math.min(retryMs * 2, 60_000);
		};
	};

	connect();
}
