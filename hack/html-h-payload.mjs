#!/usr/bin/env node
// Print the decompressed payload of ttyd's generated `src/html.h` to stdout.
//
// The header holds the gzipped, inlined index.html that ttyd embeds in the binary, as a C byte array,
// and the gzip member records an mtime — so two builds of identical content do not hash identically.
// Comparing payloads instead of the header text is what makes "did this rebuild change anything?" a
// real question. Used by hack/build-ttyd-client.sh.
//
//   node hack/html-h-payload.mjs vendor/ttyd/src/html.h | sha256sum

import { readFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';

const file = process.argv[2];
if (!file) {
  console.error('usage: html-h-payload.mjs <path to html.h>');
  process.exit(2);
}
const text = readFileSync(file, 'utf8');
// xxd -i names the array after the file, so it is `index_html` here (a file called index.html.gz would
// give gzip_index_html); accept either rather than assuming what a future gulpfile does.
const body = (
  text.match(/(?:unsigned\s+char\s+)?(?:gzip_)?index_html\[[^\]]*\]\s*=\s*\{([^}]*)\}/s) ||
  text.match(/(?:unsigned\s+char\s+)?\w+\[\]\s*=\s*\{([^}]*)\}/s)
);
if (!body) {
  console.error(`${file}: no byte array found (is this ttyd's generated html.h?)`);
  process.exit(2);
}
const bytes = Uint8Array.from(body[1].match(/0x[0-9a-f]{2}/gi) ?? [], (h) => parseInt(h, 16));
if (!bytes.length) {
  console.error(`${file}: the byte array is empty`);
  process.exit(2);
}
process.stdout.write(gunzipSync(bytes));
