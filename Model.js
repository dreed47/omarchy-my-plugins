// Pure logic for My Plugins: parse the marketplace catalog and engagement
// stats, keep the plugins this machine's owner listed (or installed), and
// format the bar pill / popup. No QML and no filesystem access here, so the
// same file loads in Quickshell and in node for the offline suite.
//
// Everything stays ES5: the QML JS engine is what has to run it.

var MAX_BODY_CHARS = 16000000
var CATALOG_MAX_AGE_SEC = 21600
var STATS_MAX_AGE_SEC = 1800
var MAX_INSTALLED = 256
var MAX_MANIFEST_BYTES = 8192

var SORTS = ["views", "copies", "hearts", "stars", "newest", "name"]

var glyph = {
  puzzle: "\uf12e",
  heart: "\uf004",
  eye: "\uf06e",
  copy: "\uf0c5",
  star: "\uf005",
  alert: "\uf071",
  check: "\uf00c"
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

// curl is invoked with -D - -o - -w '\n%{http_code}', so one stdout carries
// headers, a blank line, the body, and the status on the final line.
function parseHttpResponse(text) {
  var s = String(text || "")
  var out = { status: 0, etag: "", body: "" }
  if (!s) return out

  var nl = s.lastIndexOf("\n")
  if (nl >= 0) {
    var tail = s.slice(nl + 1).trim()
    if (/^\d{3}$/.test(tail)) {
      out.status = parseInt(tail, 10)
      s = s.slice(0, nl)
    }
  }

  var sep = s.indexOf("\r\n\r\n") >= 0 ? "\r\n\r\n" : "\n\n"
  var idx = -1
  var probe = 0
  while (true) {
    var found = s.indexOf(sep, probe)
    if (found < 0) break
    var after = s.slice(found + sep.length, found + sep.length + 5)
    if (/^HTTP\//.test(after)) {
      probe = found + sep.length
      continue
    }
    idx = found
    break
  }
  if (idx < 0) {
    out.body = ""
    return out
  }

  var head = s.slice(0, idx)
  out.body = s.slice(idx + sep.length)

  var lines = head.replace(/\r/g, "").split("\n")
  for (var i = lines.length - 1; i >= 0; i--) {
    var m = /^etag:\s*(.+)$/i.exec(lines[i])
    if (m) {
      out.etag = m[1].trim()
      break
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

function parseCatalog(text) {
  var raw
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return []
  }
  if (!raw || typeof raw !== "object") return []
  var list = Array.isArray(raw.plugins) ? raw.plugins : []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || typeof m !== "object") continue
    var id = String(m.id || "")
    if (!id) continue
    out.push({
      id: id,
      name: String(m.name || prettyName(id)),
      description: String(m.description || ""),
      author: String(m.author || authorFromRepo(m.repo)),
      version: String(m.version || ""),
      repo: String(m.repo || ""),
      listedAt: String(m.listedAt || m.addedAt || ""),
      kind: String(m.kind || ""),
      category: String(m.category || ""),
      stars: Number(m.stars) || 0,
      verified: String(m.verificationStatus || "") === "verified",
      verification: String(m.verificationCoverage || m.verificationStatus || ""),
      listed: true,
      local: false,
      views: 0,
      copies: 0,
      hearts: 0
    })
  }
  return out
}

function prettyName(id) {
  var parts = String(id || "").split(".")
  var last = parts.length ? parts[parts.length - 1] : ""
  return last.replace(/[-_]+/g, " ").replace(/\b\w/g, function (c) {
    return c.toUpperCase()
  })
}

function authorFromRepo(repo) {
  var m = /^https?:\/\/github\.com\/([^\/]+)/i.exec(String(repo || ""))
  return m ? m[1] : ""
}

function githubUserFromId(id) {
  var m = /^io\.github\.([^.]+)\./i.exec(String(id || ""))
  return m ? m[1] : ""
}

// Accept a username, @user, or a github.com/user URL. Anything else is stripped
// so a paste cannot smuggle a second command into the setting.
function normalizeGithubUser(value) {
  var s = String(value || "").trim().split(/\s+/)[0] || ""
  s = s.replace(/^https?:\/\/(www\.)?github\.com\//i, "")
  if (s.charAt(0) === "@") s = s.slice(1)
  s = s.split(/[\/?#]/)[0]
  if (!/^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$/.test(s)) return ""
  return s
}

function parseStats(text) {
  var raw
  try {
    raw = JSON.parse(String(text || ""))
  } catch (e) {
    return {}
  }
  var p = raw && raw.plugins
  return p && typeof p === "object" ? p : {}
}

function join(plugins, stats, nowMs) {
  var out = []
  for (var i = 0; i < plugins.length; i++) {
    var p = plugins[i]
    var s = stats[p.id]
    var c = {}
    for (var k in p) {
      if (Object.prototype.hasOwnProperty.call(p, k)) c[k] = p[k]
    }
    c.views = (s && Number(s.views)) || 0
    c.copies = (s && Number(s.copies)) || 0
    c.hearts = (s && Number(s.hearts)) || 0
    c.ageDays = ageDays(p.listedAt, nowMs)
    out.push(c)
  }
  return out
}

function ageDays(listedAt, nowMs) {
  var t = Date.parse(String(listedAt || ""))
  if (!isFinite(t)) return 0
  var d = (Number(nowMs) - t) / 86400000
  return d > 0.5 ? d : 0.5
}

// ---------------------------------------------------------------------------
// Owner matching
// ---------------------------------------------------------------------------

function normalizeOwner(owner) {
  var o = owner || {}
  return {
    githubUser: String(o.githubUser || "").trim().toLowerCase(),
    authorName: String(o.authorName || "").trim().toLowerCase(),
    idPrefix: String(o.idPrefix || "").trim().toLowerCase()
  }
}

function ownerIsEmpty(owner) {
  var o = normalizeOwner(owner)
  return !o.githubUser && !o.authorName && !o.idPrefix
}

function matchesOwner(plugin, owner) {
  var o = normalizeOwner(owner)
  if (ownerIsEmpty(o)) return false
  var id = String(plugin && plugin.id || "").toLowerCase()
  var repo = String(plugin && plugin.repo || "").toLowerCase()
  var author = String(plugin && plugin.author || "").toLowerCase()

  if (o.idPrefix && id.indexOf(o.idPrefix) === 0) return true
  if (o.githubUser) {
    if (id.indexOf("io.github." + o.githubUser + ".") === 0) return true
    if (repo.indexOf("https://github.com/" + o.githubUser + "/") === 0) return true
    if (repo.indexOf("https://github.com/" + o.githubUser + ".git") === 0) return true
  }
  if (o.authorName && author === o.authorName) return true
  return false
}

function ownedPlugins(rows, owner) {
  var out = []
  for (var i = 0; i < rows.length; i++) {
    if (matchesOwner(rows[i], owner)) out.push(rows[i])
  }
  return out
}

// Pick the GitHub user who owns the most locally installed io.github.* plugins,
// ignoring this dashboard itself. That is how a fresh install finds "you"
// without a setting, and how another author can use the same plugin.
function inferGithubUser(installed, selfId) {
  var counts = {}
  var skip = String(selfId || "")
  for (var id in installed) {
    if (!Object.prototype.hasOwnProperty.call(installed, id)) continue
    if (id === skip) continue
    var user = githubUserFromId(id)
    if (!user) continue
    counts[user] = (counts[user] || 0) + 1
  }
  var best = ""
  var n = 0
  for (var u in counts) {
    if (!Object.prototype.hasOwnProperty.call(counts, u)) continue
    if (counts[u] > n || (counts[u] === n && u < best)) {
      best = u
      n = counts[u]
    }
  }
  return n > 0 ? best : ""
}

function parseInstalled(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  var n = 0
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line || line.charAt(0) !== "{") continue
    var row
    try {
      row = JSON.parse(line)
    } catch (e) {
      continue
    }
    if (!row || !row.id) continue
    if (n >= MAX_INSTALLED) break
    out[String(row.id)] = {
      id: String(row.id),
      name: String(row.name || prettyName(row.id)),
      version: String(row.version || ""),
      author: String(row.author || ""),
      dir: String(row.dir || ""),
      repo: String(row.repo || "")
    }
    n++
  }
  return out
}

// Add locally installed owner plugins that the marketplace has not listed
// yet, so MakerWorld / Tempest Weather still appear, without fake stats.
function mergeLocal(owned, installed, owner) {
  var seen = {}
  var out = []
  for (var i = 0; i < owned.length; i++) {
    seen[owned[i].id] = true
    var row = owned[i]
    var rec = installed && installed[row.id]
    if (rec) {
      var c = {}
      for (var k in row) {
        if (Object.prototype.hasOwnProperty.call(row, k)) c[k] = row[k]
      }
      c.local = true
      if (!c.version && rec.version) c.version = rec.version
      out.push(c)
    } else {
      out.push(row)
    }
  }
  for (var id in installed) {
    if (!Object.prototype.hasOwnProperty.call(installed, id)) continue
    if (seen[id]) continue
    var rec2 = installed[id]
    if (!matchesOwner(rec2, owner)) continue
    out.push({
      id: rec2.id,
      name: rec2.name,
      description: "",
      author: rec2.author,
      version: rec2.version,
      repo: rec2.repo || repoGuess(rec2.id),
      listedAt: "",
      kind: "",
      category: "",
      stars: 0,
      verified: false,
      verification: "unlisted",
      listed: false,
      local: true,
      views: 0,
      copies: 0,
      hearts: 0,
      ageDays: 0
    })
  }
  return out
}

function repoGuess(id) {
  var user = githubUserFromId(id)
  if (!user) return ""
  var parts = String(id).split(".")
  var slug = parts.length ? parts[parts.length - 1] : ""
  if (!slug) return ""
  return "https://github.com/" + user + "/omarchy-" + slug
}

// ---------------------------------------------------------------------------
// Sort / totals
// ---------------------------------------------------------------------------

function sortLabel(key) {
  if (key === "copies") return "COPIES"
  if (key === "hearts") return "HEARTS"
  if (key === "stars") return "STARS"
  if (key === "newest") return "NEWEST"
  if (key === "name") return "NAME"
  return "VIEWS"
}

function sortOption(key) {
  if (key === "copies") return "Copies"
  if (key === "hearts") return "Hearts"
  if (key === "stars") return "Stars"
  if (key === "newest") return "Newest"
  if (key === "name") return "Name"
  return "Views"
}

function sortKey(label) {
  var m = String(label || "views").toLowerCase()
  if (m === "copies" || m === "installs") return "copies"
  if (m === "hearts") return "hearts"
  if (m === "stars") return "stars"
  if (m === "newest") return "newest"
  if (m === "name") return "name"
  return "views"
}

function sort(rows, key) {
  var copy = rows.slice()
  var k = SORTS.indexOf(key) >= 0 ? key : "views"
  copy.sort(function (a, b) {
    if (k === "name") return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    if (k === "newest") {
      var ta = Date.parse(a.listedAt) || 0
      var tb = Date.parse(b.listedAt) || 0
      if (tb !== ta) return tb - ta
      return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
    }
    var listedDelta = (b.listed ? 1 : 0) - (a.listed ? 1 : 0)
    if (listedDelta) return listedDelta
    var va = Number(a[k]) || 0
    var vb = Number(b[k]) || 0
    if (vb !== va) return vb - va
    return a.name.toLowerCase() < b.name.toLowerCase() ? -1 : 1
  })
  return copy
}

function nextSort(key) {
  var i = SORTS.indexOf(key)
  if (i < 0) return SORTS[0]
  return SORTS[(i + 1) % SORTS.length]
}

function totals(rows) {
  var t = {
    plugins: 0,
    listed: 0,
    unlisted: 0,
    views: 0,
    copies: 0,
    hearts: 0,
    stars: 0
  }
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i]
    t.plugins++
    if (r.listed) {
      t.listed++
      t.views += Number(r.views) || 0
      t.copies += Number(r.copies) || 0
      t.hearts += Number(r.hearts) || 0
      t.stars += Number(r.stars) || 0
    } else {
      t.unlisted++
    }
  }
  return t
}

// ---------------------------------------------------------------------------
// Display
// ---------------------------------------------------------------------------

function compact(n) {
  var v = Number(n) || 0
  if (v >= 10000) return Math.round(v / 1000) + "k"
  if (v >= 1000) return (v / 1000).toFixed(1).replace(/\.0$/, "") + "k"
  return String(Math.round(v))
}

function statText(n, listed) {
  if (!listed) return "—"
  return compact(n)
}

function verificationLabel(row) {
  if (!row) return ""
  if (!row.listed) return "not listed"
  if (row.verification === "snapshot-verified" || row.verified) return "verified"
  if (row.verification) return String(row.verification)
  return "unverified"
}

function listingUrl(id) {
  var s = String(id || "").trim()
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,120}$/.test(s)) return ""
  return "https://plugins.omarchy.org/plugin.html?id=" + encodeURIComponent(s)
}

function repoUrl(repo) {
  var s = String(repo || "").trim()
  return /^https:\/\/github\.com\/[A-Za-z0-9._\/-]+$/.test(s) ? s : ""
}

function ageText(listedAt, nowMs) {
  var t = Date.parse(String(listedAt || ""))
  if (!isFinite(t)) return ""
  var d = Math.floor((Number(nowMs) - t) / 86400000)
  if (d <= 0) return "today"
  if (d === 1) return "1d"
  if (d < 30) return d + "d"
  var mo = Math.floor(d / 30)
  return mo === 1 ? "1mo" : mo + "mo"
}

function flagOn(value, fallback) {
  if (value === undefined || value === null || String(value) === "") return fallback === true
  var s = String(value).toLowerCase()
  if (s === "on" || s === "true" || s === "1") return true
  if (s === "off" || s === "false" || s === "0") return false
  return fallback === true
}

function onOff(value) {
  return value ? "On" : "Off"
}

function defaultBarFlags() {
  return { count: true, views: true, copies: false, hearts: false, stars: false }
}

function barFlagsFromSettings(settings) {
  var s = settings || {}
  return {
    count: flagOn(s.barCount, true),
    views: flagOn(s.barViews, true),
    copies: flagOn(s.barCopies, false),
    hearts: flagOn(s.barHearts, false),
    stars: flagOn(s.barStars, false)
  }
}

function barParts(totalsObj, flags) {
  var t = totalsObj || totals([])
  var f = flags || defaultBarFlags()
  var parts = []
  if (f.count) parts.push(String(t.plugins || 0))
  if (f.views) parts.push(compact(t.views))
  if (f.copies) parts.push(compact(t.copies))
  if (f.hearts) parts.push(compact(t.hearts))
  if (f.stars) parts.push(compact(t.stars))
  return parts
}

function barText(totalsObj, opts) {
  var o = opts || {}
  var flags = o.bar || defaultBarFlags()
  var parts = barParts(totalsObj, flags)
  if (o.vertical) {
    if (parts.length === 0) return glyph.puzzle
    return glyph.puzzle + "\n" + parts.join("\n")
  }
  if (parts.length === 0) return glyph.puzzle
  return glyph.puzzle + " " + parts.join(" · ")
}

function tooltip(totalsObj, owner) {
  var t = totalsObj || totals([])
  var who = owner && owner.githubUser ? owner.githubUser : "your plugins"
  if (!t.plugins) return "My Plugins — no listings for " + who
  return "My Plugins — " + t.plugins + (t.plugins === 1 ? " plugin" : " plugins")
    + " · " + compact(t.views) + " views · " + compact(t.copies) + " copies · "
    + compact(t.hearts) + " hearts"
}

function statusLines(rows, totalsObj, owner) {
  var t = totalsObj || totals(rows)
  var who = owner && owner.githubUser ? owner.githubUser : "you"
  var out = ["My Plugins — " + who, compact(t.views) + " views · "
    + compact(t.copies) + " copies · " + compact(t.hearts) + " hearts"]
  for (var i = 0; i < rows.length && i < 8; i++) {
    var r = rows[i]
    out.push(r.name + "  " + statText(r.views, r.listed) + " views")
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    MAX_BODY_CHARS: MAX_BODY_CHARS,
    CATALOG_MAX_AGE_SEC: CATALOG_MAX_AGE_SEC,
    STATS_MAX_AGE_SEC: STATS_MAX_AGE_SEC,
    MAX_INSTALLED: MAX_INSTALLED,
    MAX_MANIFEST_BYTES: MAX_MANIFEST_BYTES,
    SORTS: SORTS,
    glyph: glyph,
    parseHttpResponse: parseHttpResponse,
    parseCatalog: parseCatalog,
    parseStats: parseStats,
    prettyName: prettyName,
    authorFromRepo: authorFromRepo,
    githubUserFromId: githubUserFromId,
    normalizeGithubUser: normalizeGithubUser,
    join: join,
    ageDays: ageDays,
    normalizeOwner: normalizeOwner,
    ownerIsEmpty: ownerIsEmpty,
    matchesOwner: matchesOwner,
    ownedPlugins: ownedPlugins,
    inferGithubUser: inferGithubUser,
    parseInstalled: parseInstalled,
    mergeLocal: mergeLocal,
    repoGuess: repoGuess,
    sortLabel: sortLabel,
    sortOption: sortOption,
    sortKey: sortKey,
    sort: sort,
    nextSort: nextSort,
    totals: totals,
    compact: compact,
    statText: statText,
    verificationLabel: verificationLabel,
    listingUrl: listingUrl,
    repoUrl: repoUrl,
    ageText: ageText,
    flagOn: flagOn,
    onOff: onOff,
    defaultBarFlags: defaultBarFlags,
    barFlagsFromSettings: barFlagsFromSettings,
    barParts: barParts,
    barText: barText,
    tooltip: tooltip,
    statusLines: statusLines
  }
}
