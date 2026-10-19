import streamDeck from "@elgato/streamdeck";
import { execFileSync } from "node:child_process";

import { Wake } from "./actions/wake";
import { watchEntity } from "./home-assistant";
import { setNight } from "./night";

const HA_URL = "http://192.168.0.40:8123";
const ENTITY_ID = "input_boolean.night_mode";
const KEYCHAIN_SERVICE = "stream-deck-night-mode";

streamDeck.actions.registerAction(new Wake());
await streamDeck.connect();

let token: string | undefined;
try {
	token = execFileSync("/usr/bin/security", ["find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"], { encoding: "utf8" }).trim();
} catch (err) {
	streamDeck.logger.error(`no Home Assistant token in Keychain item "${KEYCHAIN_SERVICE}": ${err}`);
}

if (token) {
	watchEntity(HA_URL, token, ENTITY_ID, (state) => void setNight(state === "on"));
}
