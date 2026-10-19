// Renders the plugin icon (a crescent moon) as the 256 px and 512 px PNGs the manifest requires.
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { deflateSync } from "node:zlib";

const dir = path.resolve("xyz.stjhn.night-mode.sdPlugin/imgs/plugin");

const crcTable = Array.from({ length: 256 }, (_, n) => {
	let c = n;
	for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
	return c >>> 0;
});
const crc32 = (buf) => {
	let c = 0xffffffff;
	for (const b of buf) c = crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
	return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
	const body = Buffer.concat([Buffer.from(type), data]);
	const len = Buffer.alloc(4);
	len.writeUInt32BE(data.length);
	const crc = Buffer.alloc(4);
	crc.writeUInt32BE(crc32(body));
	return Buffer.concat([len, body, crc]);
};

function png(size) {
	const raw = Buffer.alloc(size * (size * 3 + 1));
	for (let y = 0; y < size; y++) {
		const row = y * (size * 3 + 1);
		for (let x = 0; x < size; x++) {
			const u = (x + 0.5) / size;
			const v = (y + 0.5) / size;
			const moon = (u - 0.5) ** 2 + (v - 0.5) ** 2 < 0.3 ** 2 && (u - 0.62) ** 2 + (v - 0.4) ** 2 >= 0.25 ** 2;
			raw.set(moon ? [235, 235, 245] : [20, 24, 48], row + 1 + x * 3);
		}
	}
	const header = Buffer.alloc(13);
	header.writeUInt32BE(size, 0);
	header.writeUInt32BE(size, 4);
	header.set([8, 2, 0, 0, 0], 8);
	return Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk("IHDR", header),
		chunk("IDAT", deflateSync(raw)),
		chunk("IEND", Buffer.alloc(0)),
	]);
}

mkdirSync(dir, { recursive: true });
writeFileSync(path.join(dir, "icon.png"), png(256));
writeFileSync(path.join(dir, "icon@2x.png"), png(512));
