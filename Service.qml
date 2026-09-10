import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless half of My Plugins: fetches the public marketplace catalog and
// engagement stats, caches them, and publishes the owner's rows for the pill
// and popup. Nothing about the user is sent; both endpoints are unauthenticated
// reads. curl is the only helper — a stock Omarchy session has no node on PATH.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.dreed47.my-plugins"
  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/my-plugins"
  readonly property string catalogPath: stateDir + "/catalog.json"
  readonly property string statsPath: stateDir + "/stats.json"
  readonly property string internalPath: stateDir + "/internal.json"

  readonly property string catalogUrl: "https://plugins.omarchy.org/catalog.json"
  readonly property string statsUrl: "https://api.omarchyplugins.com/v1/stats"
  readonly property int pollIntervalSec: 1800
  readonly property int fetchTimeoutSec: 30

  property string githubUser: ""
  property string authorName: ""
  property string idPrefix: ""
  property string sortMode: "Views"
  property string showUnlistedMode: "On"
  property string barCountMode: "On"
  property string barViewsMode: "On"
  property string barCopiesMode: "Off"
  property string barHeartsMode: "Off"
  property string barStarsMode: "Off"
  property var barFlags: ({ count: true, views: true, copies: false, hearts: false, stars: false })

  property string catalogText: ""
  property string statsText: ""
  property string catalogEtag: ""
  property double catalogFetchedAt: 0
  property double statsFetchedAt: 0
  property var installed: ({})
  property var ownedRows: []
  property var totals: ({ plugins: 0, listed: 0, unlisted: 0, views: 0, copies: 0, hearts: 0, stars: 0 })
  property var owner: ({ githubUser: "", authorName: "", idPrefix: "" })
  property string guessedUser: ""
  property bool userIsGuessed: true
  property string lastError: ""
  property bool cacheLoaded: false
  property bool fetchingCatalog: false
  property bool fetchingStats: false
  property bool ready: false

  signal storeChanged()

  function pickFromEntry(entry, key, dflt) {
    if (entry && entry[key] !== undefined && entry[key] !== null && String(entry[key]) !== "")
      return entry[key]
    return dflt
  }

  function readSettings() {
    var cfg = shellConfigFile.text()
    if (!cfg) return
    var data
    try { data = JSON.parse(cfg) } catch (e) { return }
    var bar = data && data.bar
    var layout = bar && bar.layout ? bar.layout : {}
    var secs = ["left", "center", "right"]
    for (var s = 0; s < secs.length; s++) {
      var arr = layout[secs[s]] || []
      for (var i = 0; i < arr.length; i++) {
        var it = arr[i]
        if (!it || (it.id !== root.pluginId && it.module !== root.pluginId)) continue
        root.githubUser = String(pickFromEntry(it, "githubUser", ""))
        root.authorName = String(pickFromEntry(it, "authorName", ""))
        root.idPrefix = String(pickFromEntry(it, "idPrefix", ""))
        root.sortMode = String(pickFromEntry(it, "sort", "Views"))
        root.showUnlistedMode = String(pickFromEntry(it, "showUnlisted", "On"))
        root.barCountMode = String(pickFromEntry(it, "barCount", "On"))
        root.barViewsMode = String(pickFromEntry(it, "barViews", "On"))
        root.barCopiesMode = String(pickFromEntry(it, "barCopies", "Off"))
        root.barHeartsMode = String(pickFromEntry(it, "barHearts", "Off"))
        root.barStarsMode = String(pickFromEntry(it, "barStars", "Off"))
        return
      }
    }
  }

  function currentOwner() {
    var configured = Model.normalizeGithubUser(root.githubUser)
    root.guessedUser = Model.inferGithubUser(root.installed, root.pluginId)
    root.userIsGuessed = configured === ""
    var user = configured || root.guessedUser
    return {
      githubUser: user,
      authorName: String(root.authorName || "").trim(),
      idPrefix: String(root.idPrefix || "").trim()
    }
  }

  function applyOwnerSettings(values) {
    if (!values) return
    if (values.githubUser !== undefined)
      root.githubUser = Model.normalizeGithubUser(values.githubUser)
    if (values.authorName !== undefined)
      root.authorName = String(values.authorName || "")
    if (values.idPrefix !== undefined)
      root.idPrefix = String(values.idPrefix || "")
    if (values.sort !== undefined)
      root.sortMode = String(values.sort || "Views")
    if (values.showUnlisted !== undefined)
      root.showUnlistedMode = String(values.showUnlisted || "On")
    if (values.barCount !== undefined) root.barCountMode = String(values.barCount)
    if (values.barViews !== undefined) root.barViewsMode = String(values.barViews)
    if (values.barCopies !== undefined) root.barCopiesMode = String(values.barCopies)
    if (values.barHearts !== undefined) root.barHeartsMode = String(values.barHearts)
    if (values.barStars !== undefined) root.barStarsMode = String(values.barStars)
    root.rebuild()
  }

  function currentBarFlags() {
    return Model.barFlagsFromSettings({
      barCount: root.barCountMode,
      barViews: root.barViewsMode,
      barCopies: root.barCopiesMode,
      barHearts: root.barHeartsMode,
      barStars: root.barStarsMode
    })
  }

  function showUnlisted() {
    var v = String(root.showUnlistedMode || "On").toLowerCase()
    return v === "on" || v === "true" || v === "1"
  }

  function rebuild() {
    var plugins = Model.parseCatalog(root.catalogText)
    if (root.catalogText !== "" && plugins.length === 0) {
      root.catalogFetchedAt = 0
      root.catalogEtag = ""
      root.poll()
    }
    var stats = Model.parseStats(root.statsText)
    var joined = Model.join(plugins, stats, Date.now())
    root.owner = root.currentOwner()
    var owned = Model.ownedPlugins(joined, root.owner)
    if (root.showUnlisted()) owned = Model.mergeLocal(owned, root.installed, root.owner)
    var kept = []
    for (var i = 0; i < owned.length; i++) {
      if (owned[i].id !== root.pluginId) kept.push(owned[i])
    }
    owned = Model.sort(kept, Model.sortKey(root.sortMode))
    root.ownedRows = owned
    root.totals = Model.totals(owned)
    root.barFlags = root.currentBarFlags()
    root.ready = root.cacheLoaded
    root.storeChanged()
  }

  function fetchArgs(url, etag) {
    var a = ["curl", "-sS", "--proto", "=https", "--compressed",
      "--max-time", String(root.fetchTimeoutSec),
      "--max-filesize", String(Model.MAX_BODY_CHARS),
      "-D", "-", "-o", "-", "-w", "\n%{http_code}",
      "-H", "User-Agent: my-plugins/0.1 (Omarchy bar widget; github.com/dreed47/omarchy-my-plugins)"]
    if (etag) {
      a.push("-H")
      a.push("If-None-Match: " + etag)
    }
    a.push("--")
    a.push(url)
    return a
  }

  function poll() {
    if (!root.cacheLoaded) return
    root.readSettings()
    var now = Date.now()
    if (!root.fetchingStats && (now - root.statsFetchedAt) / 1000 >= Model.STATS_MAX_AGE_SEC) {
      root.fetchingStats = true
      statsProc.command = root.fetchArgs(root.statsUrl, "")
      statsProc.running = true
    }
    if (!root.fetchingCatalog && (now - root.catalogFetchedAt) / 1000 >= Model.CATALOG_MAX_AGE_SEC) {
      root.fetchingCatalog = true
      catalogProc.command = root.fetchArgs(root.catalogUrl, root.catalogEtag)
      catalogProc.running = true
    }
  }

  function refreshIfStale() {
    root.scanInstalled()
    root.poll()
  }

  function refreshNow() {
    root.catalogFetchedAt = 0
    root.statsFetchedAt = 0
    root.refreshIfStale()
  }

  function scanInstalled() {
    installedProc.command = ["bash", "-c",
      "cd \"$HOME/.config/omarchy/plugins\" 2>/dev/null || exit 0; "
      + "n=0; for d in */; do "
      + "[ -f \"$d/manifest.json\" ] || continue; "
      + "n=$((n+1)); [ $n -gt " + Model.MAX_INSTALLED + " ] && break; "
      + "head -c " + Model.MAX_MANIFEST_BYTES + " -- \"$d/manifest.json\" 2>/dev/null "
      + "| jq -c --arg d \"${d%/}\" '{id,name,version,author,dir:$d}' 2>/dev/null; "
      + "done; true"]
    installedProc.running = true
  }

  function onCatalogResponse(raw) {
    if (!root.fetchingCatalog) return
    root.fetchingCatalog = false
    var r = Model.parseHttpResponse(raw)
    if (r.status === 304) {
      root.catalogFetchedAt = Date.now()
      root.persistInternal()
      return
    }
    if (r.status !== 200 || !r.body) {
      root.lastError = "catalog fetch failed"
      root.storeChanged()
      return
    }
    var probe = Model.parseCatalog(r.body)
    if (!probe.length) {
      root.lastError = "catalog response was not usable"
      root.storeChanged()
      return
    }
    root.catalogText = r.body
    root.catalogEtag = r.etag
    root.catalogFetchedAt = Date.now()
    root.lastError = ""
    catalogFile.setText(r.body)
    root.persistInternal()
    root.rebuild()
  }

  function onStatsResponse(raw) {
    if (!root.fetchingStats) return
    root.fetchingStats = false
    var r = Model.parseHttpResponse(raw)
    if (r.status !== 200 || !r.body) {
      root.lastError = "stats fetch failed"
      root.storeChanged()
      return
    }
    var probe = Model.parseStats(r.body)
    var any = false
    for (var k in probe) { any = true; break }
    if (!any) return
    root.statsText = r.body
    root.statsFetchedAt = Date.now()
    root.lastError = ""
    statsFile.setText(r.body)
    root.persistInternal()
    root.rebuild()
  }

  function persistInternal() {
    internalFile.setText(JSON.stringify({
      catalogEtag: root.catalogEtag,
      catalogFetchedAt: root.catalogFetchedAt,
      statsFetchedAt: root.statsFetchedAt
    }))
  }

  function loadInternal(text) {
    var d
    try { d = JSON.parse(String(text || "")) } catch (e) { d = null }
    if (d && typeof d === "object") {
      root.catalogEtag = String(d.catalogEtag || "")
      root.catalogFetchedAt = Number(d.catalogFetchedAt) || 0
      root.statsFetchedAt = Number(d.statsFetchedAt) || 0
    }
    root.cacheLoaded = true
    root.scanInstalled()
    root.rebuild()
    root.poll()
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: {
      catalogFile.reload()
      statsFile.reload()
      internalFile.reload()
    }
  }

  Process {
    id: catalogProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onCatalogResponse(text)
    }
    onExited: function (code) {
      if (code !== 0 && root.fetchingCatalog) {
        root.fetchingCatalog = false
        root.lastError = "catalog fetch failed"
        root.storeChanged()
      }
    }
  }

  Process {
    id: statsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onStatsResponse(text)
    }
    onExited: function (code) {
      if (code !== 0 && root.fetchingStats) {
        root.fetchingStats = false
        root.lastError = "stats fetch failed"
        root.storeChanged()
      }
    }
  }

  Process {
    id: installedProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.installed = Model.parseInstalled(text)
        root.rebuild()
      }
    }
  }

  FileView {
    id: catalogFile
    path: root.catalogPath
    atomicWrites: true
    printErrors: false
    onLoaded: { root.catalogText = text(); root.rebuild() }
    onLoadFailed: root.catalogText = ""
  }

  FileView {
    id: statsFile
    path: root.statsPath
    atomicWrites: true
    printErrors: false
    onLoaded: { root.statsText = text(); root.rebuild() }
    onLoadFailed: root.statsText = ""
  }

  FileView {
    id: internalFile
    path: root.internalPath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadInternal(text())
    onLoadFailed: root.loadInternal("")
  }

  FileView {
    id: shellConfigFile
    path: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/omarchy/shell.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { root.readSettings(); root.rebuild() }
  }

  Timer {
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.poll()
  }
}
