// Generates the bundled Night profile: every key of a 15-key Stream Deck runs the Wake action,
// whose image is plain black. Same zip layout as the profiles Elgato ships with its plugins.
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const plugin = path.resolve("xyz.stjhn.night-mode.sdPlugin");
const profileId = "B302596A-96B9-48E9-834A-8B28FA6D923A";

const key = {
	Name: "Wake",
	Settings: {},
	State: 0,
	States: [{ Image: "", Title: "", TitleShow: "" }],
	UUID: "xyz.stjhn.night-mode.wake",
};

const Actions = {};
for (let col = 0; col < 5; col++) for (let row = 0; row < 3; row++) Actions[`${col},${row}`] = key;

const work = mkdtempSync(path.join(tmpdir(), "night-profile-"));
const dir = path.join(work, `${profileId}.sdProfile`);
mkdirSync(dir);
writeFileSync(
	path.join(dir, "manifest.json"),
	JSON.stringify({
		Actions,
		DeviceModel: "20GAA9902",
		InstalledByPluginUUID: "xyz.stjhn.night-mode",
		Name: "Night",
		PreconfiguredName: "Night",
		Version: "1.0",
	}),
);

const out = path.join(plugin, "profiles", "Night.streamDeckProfile");
mkdirSync(path.dirname(out), { recursive: true });
rmSync(out, { force: true });
execFileSync("zip", ["-qr", out, `${profileId}.sdProfile`], { cwd: work });
rmSync(work, { recursive: true });
console.log(`wrote ${path.relative(process.cwd(), out)}`);
