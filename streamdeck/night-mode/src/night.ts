import streamDeck from "@elgato/streamdeck";

const NIGHT_PROFILE = "profiles/Night";

let night = false;

/** Devices currently showing the Night profile. */
const blanked = new Set<string>();

export async function blank(deviceId: string): Promise<void> {
	if (blanked.has(deviceId)) return;
	blanked.add(deviceId);
	await streamDeck.profiles.switchToProfile(deviceId, NIGHT_PROFILE);
}

/** Switches back to whichever profile was active before the Night profile. */
export async function restore(deviceId: string): Promise<void> {
	if (!blanked.delete(deviceId)) return;
	await streamDeck.profiles.switchToProfile(deviceId);
}

/** The Night profile's keys report in here, so a plugin restart still knows what is showing. */
export function markBlanked(deviceId: string, showing: boolean): void {
	if (showing) blanked.add(deviceId);
	else blanked.delete(deviceId);
}

/**
 * Acts only on transitions, so a reconnect that re-reports "on" does not re-blank a deck the
 * user has already woken.
 */
export async function setNight(on: boolean): Promise<void> {
	if (on === night) return;
	night = on;
	streamDeck.logger.info(`night mode ${on ? "on" : "off"}`);
	for (const device of streamDeck.devices) {
		if (device.isConnected) await (on ? blank(device.id) : restore(device.id));
	}
}

streamDeck.devices.onDeviceDidConnect(async (ev) => {
	if (night) await blank(ev.device.id);
});

streamDeck.devices.onDeviceDidDisconnect((ev) => {
	blanked.delete(ev.device.id);
});
