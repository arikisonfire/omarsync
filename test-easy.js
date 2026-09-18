// node test-easy.js — checks Easy.js without the shell
const fs = require("fs")
const vm = require("vm")
const assert = require("assert")

const O = {}
vm.createContext(O)
vm.runInContext(fs.readFileSync(__dirname + "/Options.js", "utf8").replace(/^\.pragma library/m, ""), O)
const E = { Options: O }
vm.createContext(E)
vm.runInContext(fs.readFileSync(__dirname + "/Easy.js", "utf8")
  .replace(/^\.pragma library/m, "").replace(/^\.import .*$/m, ""), E)

let failures = 0
function test(name, fn) {
  try { fn(); console.log("ok   " + name) }
  catch (e) { failures++; console.log("FAIL " + name + "\n     " + e.message) }
}
const plain = v => JSON.parse(JSON.stringify(v))
const job = (opts, extra) => Object.assign({ src: "/a/", dst: "/b", opts: opts || {}, filters: [], extra: "" }, extra || {})
const apply = (j, k, v) => Object.assign({}, j, E.withAnswer(j, k, v))
const preset = id => O.PRESETS.find(p => p.id === id)

test("goals are read from presets, plain and adapted", () => {
  for (const g of E.GOALS) {
    assert.strictEqual(E.read(job(O.presetOpts(preset(g.id), false))).goal, g.id)
    assert.strictEqual(E.read(job(O.presetOpts(preset(g.id), true))).goal, g.id)
    assert.strictEqual(E.read(job(O.presetOpts(preset(g.id), true))).extras.length, 0)
  }
  assert.strictEqual(E.read(job({ archive: true, inplace: true })).goal, "custom")
})

test("answers round-trip and keep the goal", () => {
  let j = job(O.presetOpts(preset("mirror"), false))
  for (const [k, on, off] of [["thorough", true, false], ["safetyCopy", true, false], ["slowLink", true, false],
                              ["resume", true, false], ["bandwidth", "2", "full"]]) {
    j = apply(j, k, on)
    assert.strictEqual(E.read(j)[k], on, k + " on")
    assert.strictEqual(E.read(j).goal, "mirror", k + " keeps goal")
    assert.strictEqual(E.read(j).extras.length, 0, k + " no extras: " + E.read(j).extras)
    j = apply(j, k, off)
    assert.strictEqual(E.read(j)[k], off, k + " off")
  }
  assert.deepStrictEqual(plain(j.opts), plain(O.presetOpts(preset("mirror"), false)))
  assert.strictEqual(j.filters.length, 0)
})

test("skip sets add and remove only their rules", () => {
  let j = job({ archive: true }, { filters: [{ type: "exclude", pattern: "*.iso" }] })
  j = apply(j, "skip.caches", true)
  assert(E.read(j).skip.caches)
  assert(!E.read(j).skip.systemJunk)
  assert.deepStrictEqual(plain(E.read(j).extras), ["1 filter rule"])
  j = apply(j, "skip.caches", false)
  assert.deepStrictEqual(plain(j.filters), [{ type: "exclude", pattern: "*.iso" }])
})

test("safety copy: backup dir, protecting filter, dated run folder", () => {
  const j = apply(job(O.presetOpts(preset("mirror"), false)), "safetyCopy", true)
  assert(j.filters.some(f => f.type === "exclude" && f.pattern === "/.rsync-backup/"))
  const argv = Array.from(O.runArgs(j, "ssh", false, new Date(2026, 8, 17, 9, 5).getTime()).argv)
  assert(argv.includes("--backup-dir=.rsync-backup/2026-09-17_0905"), argv.join(" "))
  assert(argv.includes("--backup"))
  assert(argv.includes("--exclude=/.rsync-backup/"))
  assert(O.buildArgs(Object.assign({}, j, { opts: Object.assign({}, j.opts, { deleteExcluded: true }) })).warnings.some(w => /removes the backups/.test(w)))
})

test("expert-only settings are listed and survive answers", () => {
  let j = job(Object.assign({ maxSize: "500M", sshPort: 2222 }, O.presetOpts(preset("copy"), false)), { extra: "--foo" })
  assert.deepStrictEqual(plain(E.read(j).extras), ["Max file size", "SSH port", "Extra arguments"])
  j = apply(j, "thorough", true)
  assert.strictEqual(j.opts.maxSize, "500M")
  assert.strictEqual(E.read(job({ archive: true, backup: true, suffix: "~" })).extras.length, 2)
  assert.deepStrictEqual(plain(E.read(job({ archive: true, bwlimit: 512 })).extras), ["Bandwidth limit"])
})

test("summary", () => {
  const ctx = { srcName: "Nextcloud", dstName: "Backup", contentsOnly: true, remote: false, dstFs: "exFAT" }
  let j = apply(job(Object.assign({ safeNames: true }, O.presetOpts(preset("mirror"), true))), "safetyCopy", true)
  const s = E.summary(j, ctx)
  assert(/exact copy/.test(s) && /\.rsync-backup/.test(s) && /exFAT/.test(s) && /look-alike/.test(s), s)
  assert(/Choose/.test(E.summary(job({}, { src: "" }), ctx)))
})

if (failures) { console.log(failures + " failed"); process.exit(1) }
console.log("all passed")
