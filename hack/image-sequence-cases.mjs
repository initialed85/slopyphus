// Writes the case scripts that spell the same iTerm2 inline-image sequence in the ways tmux might accept.
//
// Pi emits one sequence; tmux only forwards a sequence it is told to pass through, using the form
// ESC P t m u x ; ... ESC ESC \. What is uncertain is what tmux expects *inside* that wrapper, so each
// spelling gets its own case and the byte capture says which one tmux actually forwards.
//
//   node hack/image-sequence-cases.mjs <output-dir> <tiny-png>
//
// Each case is written as <output-dir>/case-<name>.sh, which is the name hack/image-cases.sh looks for.
import fs from "node:fs";
import path from "node:path";

const [out, pngPath = "/tmp/image-test/tiny.png"] = process.argv.slice(2);
const ESC = "\x1b";
const ST = ESC + "\\";
const BEL = "\x07";

const png = fs.readFileSync(pngPath);
const b64 = png.toString("base64");
// The header Pi emits, derived in hack/pi-image-bytes.mjs: column widths and an automatic height.
const payload = `${ESC}]1337;File=inline=1;size=${png.length};width=10;height=auto;preserveAspectRatio=0:${b64}`;
const double = (s) => s.split(ESC).join(ESC + ESC);

const cases = {
  // Pi's own BEL-terminated sequence, escapes doubled, wrapper closed with ST.
  "wrap-bel": ESC + "Ptmux;" + ESC + double(payload + BEL) + ESC + ESC + "\\",
  // The same sequence with ST instead of BEL, because xterm.js only ends an OSC on ST and tmux only ends a
  // DCS on ST, so BEL is the obvious thing to suspect.
  "wrap-st": ESC + "Ptmux;" + ESC + double(payload + ST) + ESC + ESC + "\\",
  // The payload carries its own doubled ST and nothing is appended: that terminator closes the wrapper.
  "wrap-st-only": ESC + "Ptmux;" + ESC + double(payload + ST),
  // Nothing doubled inside the wrapper.
  "wrap-plain": ESC + "Ptmux;" + payload + ST + ESC + ESC + "\\",
  // The closing ST single rather than doubled. tmux/input.c's dcs_escape state table dispatches the DCS on
  // ESC followed by \\, and treats ESC ESC as one literal ESC, so a doubled closing ST is read as payload and
  // the wrapper never ends. That is why the four spellings above swallow everything that follows them.
  "wrap-st-close-single": ESC + "Ptmux;" + ESC + double(payload + ST) + ESC + "\\",
  "wrap-bel-close-single": ESC + "Ptmux;" + ESC + double(payload + BEL) + ESC + "\\",
  // Control: a wrapped colour sequence. It is known to survive tmux, so if this one fails the harness is
  // the problem rather than the sequence.
  "wrap-csi": ESC + "Ptmux;" + ESC + double(`${ESC}[42mX`) + ESC + ESC + "\\",
  "wrap-csi-close-single": ESC + "Ptmux;" + ESC + double(`${ESC}[42mX`) + ESC + "\\",
};

for (const [name, seq] of Object.entries(cases)) {
  fs.writeFileSync(path.join(out, `payload-${name}.bin`), seq, "latin1");
  fs.writeFileSync(
    path.join(out, `case-${name}.sh`),
    `cat /tmp/payload-${name}.bin\necho CASE-RAN-MARKER-${name}\n`,
  );
  console.log(`case-${name}: ${Buffer.byteLength(seq, "latin1")} bytes`);
}
