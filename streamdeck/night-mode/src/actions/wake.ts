import { action, KeyDownEvent, SingletonAction, WillAppearEvent, WillDisappearEvent } from "@elgato/streamdeck";

import { markBlanked, restore } from "../night";

/** Fills every key of the Night profile; any press brings the normal profile back. */
@action({ UUID: "xyz.stjhn.night-mode.wake" })
export class Wake extends SingletonAction {
	override onWillAppear(ev: WillAppearEvent): void {
		markBlanked(ev.action.device.id, true);
	}

	override onWillDisappear(ev: WillDisappearEvent): void {
		markBlanked(ev.action.device.id, false);
	}

	override async onKeyDown(ev: KeyDownEvent): Promise<void> {
		await restore(ev.action.device.id);
	}
}
