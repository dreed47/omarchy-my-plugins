const { test } = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const catalog = JSON.stringify({
  generatedAt: "2026-09-10T00:00:00.000Z",
  plugins: [
    {
      id: "io.github.dreed47.print-center",
      name: "Print Center",
      author: "David Reed",
      version: "0.4.1",
      repo: "https://github.com/dreed47/omarchy-print-center",
      listedAt: "2026-09-09T00:00:00.000Z",
      stars: 0,
      verificationStatus: "verified",
      verificationCoverage: "snapshot-verified"
    },
    {
      id: "io.github.dreed47.session-restore",
      name: "Session Restore",
      author: "David Reed",
      version: "2.2.0",
      repo: "https://github.com/dreed47/omarchy-session-restore",
      listedAt: "2026-09-08T00:00:00.000Z",
      stars: 1,
      verificationStatus: "verified",
      verificationCoverage: "snapshot-verified"
    },
    {
      id: "io.github.someone.else",
      name: "Else",
      author: "Someone Else",
      version: "1.0.0",
      repo: "https://github.com/someone/else",
      listedAt: "2026-01-01T00:00:00.000Z",
      stars: 9,
      verificationStatus: "unverified"
    }
  ]
})

const stats = JSON.stringify({
  schemaVersion: 1,
  plugins: {
    "io.github.dreed47.print-center": { views: 140, copies: 46, hearts: 4 },
    "io.github.dreed47.session-restore": { views: 92, copies: 22, hearts: 2 },
    "io.github.someone.else": { views: 9000, copies: 800, hearts: 50 }
  }
})

function owned() {
  const joined = Model.join(Model.parseCatalog(catalog), Model.parseStats(stats), Date.parse("2026-09-10T00:00:00Z"))
  return Model.ownedPlugins(joined, { githubUser: "dreed47" })
}

test("parseCatalog keeps name author repo and verification", () => {
  const rows = Model.parseCatalog(catalog)
  assert.equal(rows.length, 3)
  assert.equal(rows[0].name, "Print Center")
  assert.equal(rows[0].verified, true)
  assert.equal(rows[0].verification, "snapshot-verified")
})

test("parseCatalog rejects garbage", () => {
  assert.deepEqual(Model.parseCatalog("nope"), [])
  assert.deepEqual(Model.parseCatalog(""), [])
})

test("join attaches views copies hearts without mixing other plugins", () => {
  const rows = owned()
  assert.equal(rows.length, 2)
  const print = rows.find((r) => r.id.endsWith("print-center"))
  assert.equal(print.views, 140)
  assert.equal(print.copies, 46)
  assert.equal(print.hearts, 4)
})

test("matchesOwner by github id prefix and repo, not by name collision", () => {
  const row = { id: "io.github.dreed47.print-center", repo: "https://github.com/dreed47/omarchy-print-center", author: "David Reed" }
  assert.equal(Model.matchesOwner(row, { githubUser: "dreed47" }), true)
  assert.equal(Model.matchesOwner(row, { githubUser: "other" }), false)
  assert.equal(Model.matchesOwner(row, { authorName: "David Reed" }), true)
  assert.equal(Model.matchesOwner(row, { idPrefix: "io.github.dreed47." }), true)
  assert.equal(Model.matchesOwner(row, {}), false)
})

test("inferGithubUser picks the most common installed io.github user", () => {
  const installed = {
    "io.github.dreed47.print-center": {},
    "io.github.dreed47.tempest-weather": {},
    "io.github.dreed47.my-plugins": {},
    "io.github.other.thing": {}
  }
  assert.equal(Model.inferGithubUser(installed, "io.github.dreed47.my-plugins"), "dreed47")
})

test("mergeLocal prefers recorded repo over omarchy- prefix guess", () => {
  const installed = Model.parseInstalled(
    '{"id":"io.github.dreed47.tempest-weather","name":"Tempest Weather","version":"0.4.1","author":"David Reed","repo":"https://github.com/dreed47/tempest-weather"}'
  )
  const merged = Model.mergeLocal([], installed, { githubUser: "dreed47" })
  assert.equal(merged[0].repo, "https://github.com/dreed47/tempest-weather")
})

test("mergeLocal adds unlisted owner plugins without inventing stats", () => {
  const ownedRows = owned()
  const installed = Model.parseInstalled([
    '{"id":"io.github.dreed47.print-center","name":"Print Center","version":"0.4.1"}',
    '{"id":"io.github.dreed47.tempest-weather","name":"Tempest Weather","version":"0.4.1","author":"David Reed"}'
  ].join("\n"))
  const merged = Model.mergeLocal(ownedRows, installed, { githubUser: "dreed47" })
  const tempest = merged.find((r) => r.id.endsWith("tempest-weather"))
  assert.ok(tempest)
  assert.equal(tempest.listed, false)
  assert.equal(Model.statText(tempest.views, tempest.listed), "—")
})

test("sort puts listed plugins with more views first", () => {
  const sorted = Model.sort(owned(), "views")
  assert.equal(sorted[0].id, "io.github.dreed47.print-center")
  assert.equal(sorted[1].id, "io.github.dreed47.session-restore")
})

test("totals ignore unlisted stats", () => {
  const t = Model.totals(owned())
  assert.equal(t.plugins, 2)
  assert.equal(t.listed, 2)
  assert.equal(t.views, 232)
  assert.equal(t.copies, 68)
  assert.equal(t.hearts, 6)
})

test("compact and barText", () => {
  assert.equal(Model.compact(265), "265")
  assert.equal(Model.compact(1200), "1.2k")
  assert.equal(Model.barText({ plugins: 3, views: 265 }, {}), "\uf12e 3 · 265")
  assert.equal(Model.barText({ plugins: 3, views: 265, copies: 74, hearts: 8, stars: 1 }, {
    bar: { count: false, views: false, copies: true, hearts: true, stars: false }
  }), "\uf12e 74 · 8")
  assert.equal(Model.barText({ plugins: 3, views: 265 }, {
    bar: { count: false, views: false, copies: false, hearts: false, stars: false }
  }), "\uf12e")
})

test("listingUrl and repoUrl refuse hostile values", () => {
  assert.equal(Model.listingUrl("io.github.dreed47.print-center").startsWith("https://plugins.omarchy.org/plugin.html?id="), true)
  assert.equal(Model.listingUrl("io.github.dreed47.print-center\ncurl evil"), "")
  assert.equal(Model.listingUrl("../../etc/passwd"), "")
  assert.equal(Model.repoUrl("https://github.com/dreed47/omarchy-print-center"), "https://github.com/dreed47/omarchy-print-center")
  assert.equal(Model.repoUrl("https://evil.example/x"), "")
  assert.equal(Model.repoUrl("https://github.com/dreed47/omarchy-print-center\nrm"), "")
  assert.equal(Model.issueUrl("https://github.com/omacom/omarchy-plugin-marketplace/issues/6398"), "https://github.com/omacom/omarchy-plugin-marketplace/issues/6398")
  assert.equal(Model.issueUrl("https://github.com/evil/evil/issues/1"), "")
})

test("verificationLabel prefers open issue status", () => {
  assert.equal(Model.verificationLabel({
    listed: true,
    verification: "update-unverified",
    issueState: "open",
    issueStatus: "in review",
    issueNumber: 6398,
  }), "in review #6398")
  assert.equal(Model.verificationLabel({ listed: false }), "not listed")
})

test("parseHttpResponse splits status etag and body, keeps 304 empty", () => {
  const raw = "HTTP/2 200\r\nETag: \"abc\"\r\n\r\n{\"ok\":true}\n200"
  const r = Model.parseHttpResponse(raw)
  assert.equal(r.status, 200)
  assert.equal(r.etag, "\"abc\"")
  assert.equal(r.body, "{\"ok\":true}")
  const notModified = Model.parseHttpResponse("HTTP/2 304\r\nETag: \"abc\"\r\n\r\n\n304")
  assert.equal(notModified.status, 304)
  assert.equal(notModified.body, "")
})

test("nextSort cycles the advertised keys", () => {
  assert.equal(Model.nextSort("views"), "copies")
  assert.equal(Model.nextSort("name"), "views")
  assert.equal(Model.sortOption("copies"), "Copies")
})

test("normalizeGithubUser accepts @user and profile URLs", () => {
  assert.equal(Model.normalizeGithubUser("dreed47"), "dreed47")
  assert.equal(Model.normalizeGithubUser("@dreed47"), "dreed47")
  assert.equal(Model.normalizeGithubUser("https://github.com/dreed47"), "dreed47")
  assert.equal(Model.normalizeGithubUser("https://github.com/dreed47/omarchy-print-center"), "dreed47")
  assert.equal(Model.normalizeGithubUser("dreed47\ncurl evil"), "dreed47")
  assert.equal(Model.normalizeGithubUser("foo_bar"), "")
  assert.equal(Model.normalizeGithubUser(""), "")
})
