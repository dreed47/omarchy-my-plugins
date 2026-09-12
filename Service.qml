import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Headless half of My Plugins. All filesystem and network I/O lives in
// scripts/my-plugins, spawned as `/usr/bin/python3 -I` with a closed
// environment. This file only passes absolute paths on argv, applies a
// process deadline, and publishes the helper's bounded JSON.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string pluginId: "io.github.dreed47.my-plugins"
  readonly property string pythonBin: "/usr/bin/python3"
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
  readonly property string helper: pluginDir + "scripts/my-plugins"

  readonly property string home: String(Quickshell.env("HOME") || "")
  readonly property string stateDir: {
    var xdg = String(Quickshell.env("XDG_STATE_HOME") || "")
    return (xdg !== "" ? xdg : home + "/.local/state") + "/omarchy/my-plugins"
  }
  readonly property string pluginsDir: {
    var xdg = String(Quickshell.env("XDG_CONFIG_HOME") || "")
    return (xdg !== "" ? xdg : home + "/.config") + "/omarchy/plugins"
  }

  readonly property int pollIntervalSec: 1800
  readonly property int helperDeadlineMs: 30000
  readonly property int helperKillMs: 1000
  readonly property int maxStdoutChars: 262144

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

  property var ownedRows: []
  property var totals: ({ plugins: 0, listed: 0, unlisted: 0, views: 0, copies: 0, hearts: 0, stars: 0 })
  property var owner: ({ githubUser: "", authorName: "", idPrefix: "" })
  property string guessedUser: ""
  property bool userIsGuessed: true
  property string lastError: ""
  property bool ready: false
  property bool fetching: false

  signal storeChanged()

  readonly property var closedEnv: ({
    PATH: "/usr/bin:/bin",
    LC_ALL: "C",
    PYTHONNOUSERSITE: "1"
  })

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

  function currentBarFlags() {
    return Model.barFlagsFromSettings({
      barCount: root.barCountMode,
      barViews: root.barViewsMode,
      barCopies: root.barCopiesMode,
      barHearts: root.barHeartsMode,
      barStars: root.barStarsMode
    })
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
    root.barFlags = root.currentBarFlags()
    root.storeChanged()
    root.sync(false)
  }

  function helperArgs(force) {
    var a = [root.pythonBin, "-I", root.helper, "sync",
      "--home", root.home,
      "--state-dir", root.stateDir,
      "--plugins-dir", root.pluginsDir,
      "--github-user", String(root.githubUser || ""),
      "--author-name", String(root.authorName || ""),
      "--id-prefix", String(root.idPrefix || ""),
      "--show-unlisted", String(root.showUnlistedMode || "On"),
      "--sort", String(root.sortMode || "Views")]
    if (force) a.push("--force")
    return a
  }

  function sync(force) {
    root.readSettings()
    root.barFlags = root.currentBarFlags()
    if (syncProc.running) return
    root.fetching = true
    syncProc.command = root.helperArgs(force === true)
    syncProc.running = true
    deadlineTimer.restart()
  }

  function refreshIfStale() { root.sync(false) }
  function refreshNow() { root.sync(true) }

  function stopHelper(sig) {
    if (!syncProc.running) return
    syncProc.signal(sig)
  }

  function applyHelperOutput(raw) {
    root.fetching = false
    deadlineTimer.stop()
    killTimer.stop()
    var text = String(raw || "")
    if (text.length > root.maxStdoutChars) {
      root.lastError = "helper output too large"
      root.storeChanged()
      return
    }
    var data
    try { data = JSON.parse(text) } catch (e) { data = null }
    if (!data || typeof data !== "object") {
      root.lastError = "helper printed nothing usable"
      root.storeChanged()
      return
    }
    if (data.ok === false && (!data.rows || !data.rows.length)) {
      root.lastError = String(data.error || "helper failed")
      root.storeChanged()
      return
    }
    root.ownedRows = Array.isArray(data.rows) ? data.rows : []
    root.totals = data.totals && typeof data.totals === "object"
      ? data.totals
      : Model.totals(root.ownedRows)
    root.owner = data.owner && typeof data.owner === "object"
      ? data.owner
      : ({ githubUser: "", authorName: "", idPrefix: "" })
    root.guessedUser = String(data.guessedUser || "")
    root.userIsGuessed = data.userIsGuessed !== false
    root.lastError = String(data.error || "")
    root.ready = true
    root.barFlags = root.currentBarFlags()
    root.storeChanged()
  }

  Process {
    id: syncProc
    clearEnvironment: true
    environment: root.closedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onDataChanged: {
        if (text.length > root.maxStdoutChars) {
          root.lastError = "helper output too large"
          root.stopHelper(9)
        }
      }
      onStreamFinished: root.applyHelperOutput(text)
    }
    onExited: function (code) {
      deadlineTimer.stop()
      killTimer.stop()
      if (code !== 0 && root.fetching && root.lastError === "") {
        root.fetching = false
        root.lastError = "helper failed"
        root.storeChanged()
      }
    }
  }

  Timer {
    id: deadlineTimer
    interval: root.helperDeadlineMs
    repeat: false
    onTriggered: {
      if (!syncProc.running) return
      root.lastError = "helper timed out"
      root.stopHelper(15)
      killTimer.restart()
    }
  }

  Timer {
    id: killTimer
    interval: root.helperKillMs
    repeat: false
    onTriggered: {
      if (syncProc.running) root.stopHelper(9)
      root.fetching = false
      root.storeChanged()
    }
  }

  FileView {
    id: shellConfigFile
    path: (Quickshell.env("XDG_CONFIG_HOME") || root.home + "/.config") + "/omarchy/shell.json"
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: { root.readSettings(); root.barFlags = root.currentBarFlags(); root.sync(false) }
    onLoadFailed: root.sync(false)
  }

  Timer {
    interval: root.pollIntervalSec * 1000
    running: true
    repeat: true
    onTriggered: root.sync(false)
  }
}
