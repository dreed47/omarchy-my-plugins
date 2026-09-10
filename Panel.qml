import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Popup for the My Plugins bar pill: the marketplace listings this owner
// published, plus any locally installed owner plugins that are not listed
// yet. Live numbers come from Service.qml via serviceFor.
Panel {
  id: root
  moduleName: "io.github.dreed47.my-plugins"
  ipcTarget: "io.github.dreed47.my-plugins"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property bool openedFromHotkey: false
  property bool popoutSwitchClosing: false
  readonly property var barIdentity: hostWidget || root

  readonly property string pluginId: "io.github.dreed47.my-plugins"
  readonly property var svc: {
    if (root.service) return root.service
    return root.bar && root.bar.shell ? root.bar.shell.serviceFor(pluginId) : null
  }

  readonly property var rows: svc && svc.ownedRows ? svc.ownedRows : []
  readonly property var totals: svc && svc.totals ? svc.totals : ({ plugins: 0, listed: 0, unlisted: 0, views: 0, copies: 0, hearts: 0, stars: 0 })
  readonly property var owner: svc && svc.owner ? svc.owner : ({ githubUser: "", authorName: "", idPrefix: "" })
  readonly property string guessedUser: svc ? String(svc.guessedUser || "") : ""
  readonly property bool userIsGuessed: svc ? svc.userIsGuessed !== false : true
  readonly property string lastError: svc ? String(svc.lastError || "") : ""
  readonly property bool fetching: svc ? (svc.fetchingCatalog === true || svc.fetchingStats === true) : false
  readonly property bool ready: svc ? svc.ready === true : false

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color accent: Color.accent
  readonly property bool vertical: bar ? bar.vertical : false

  property int cursor: 0
  property double nowMs: Date.now()
  property bool editingSettings: false
  property string draftUser: ""
  property bool draftBarCount: true
  property bool draftBarViews: true
  property bool draftBarCopies: false
  property bool draftBarHearts: false
  property bool draftBarStars: false

  readonly property var barFlags: svc && svc.barFlags ? svc.barFlags : Model.defaultBarFlags()
  readonly property string label: Model.barText(root.totals, { vertical: root.vertical, bar: root.barFlags })
  readonly property string tooltip: Model.tooltip(root.totals, root.owner)

  function statusLines() {
    return Model.statusLines(root.rows, root.totals, root.owner)
  }

  function refresh() {
    if (svc && svc.refreshNow) svc.refreshNow()
    else if (svc && svc.refreshIfStale) svc.refreshIfStale()
    root.nowMs = Date.now()
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    if (svc && svc.refreshIfStale) svc.refreshIfStale()
    root.nowMs = Date.now()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    if (svc && svc.refreshIfStale) svc.refreshIfStale()
    Qt.callLater(function () {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    if (root.editingSettings) root.cancelEditingSettings()
    root.controller.hide()
  }

  function closeForPopoutSwitch() {
    root.popoutSwitchClosing = true
    root.close()
    Qt.callLater(function () { root.popoutSwitchClosing = false })
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function moveCursor(delta) {
    if (root.rows.length === 0) {
      root.cursor = 0
      return
    }
    var next = root.cursor + delta
    if (next < 0) next = root.rows.length - 1
    if (next >= root.rows.length) next = 0
    root.cursor = next
  }

  function currentRow() {
    if (root.cursor < 0 || root.cursor >= root.rows.length) return null
    return root.rows[root.cursor]
  }

  function openUrl(url) {
    var s = String(url || "")
    if (!s) return
    Quickshell.execDetached(["omarchy-launch-browser", s])
  }

  function openListing(row) {
    var r = row || root.currentRow()
    if (!r) return
    var url = r.listed ? Model.listingUrl(r.id) : Model.repoUrl(r.repo)
    root.openUrl(url)
  }

  function openRepo(row) {
    var r = row || root.currentRow()
    if (!r) return
    root.openUrl(Model.repoUrl(r.repo))
  }

  function cycleSort() {
    var current = Model.sortKey(svc ? svc.sortMode : "views")
    var next = Model.nextSort(current)
    if (sortProc.running) return
    sortProc.command = ["omarchy-bar", "set", root.ipcTarget, "sort", Model.sortOption(next)]
    sortProc.running = true
  }

  Process {
    id: sortProc
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    var src = root.settings
    if (src) {
      for (var key in src) {
        if (key !== "id") entry[key] = src[key]
      }
    }
    for (var next in values) entry[next] = values[next]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    if (svc && typeof svc.applyOwnerSettings === "function")
      svc.applyOwnerSettings(values)
  }

  function startEditingSettings() {
    var configured = Model.normalizeGithubUser(root.setting("githubUser", ""))
    root.draftUser = configured || root.guessedUser || root.owner.githubUser || ""
    var flags = root.barFlags
    root.draftBarCount = flags.count !== false
    root.draftBarViews = flags.views !== false
    root.draftBarCopies = flags.copies === true
    root.draftBarHearts = flags.hearts === true
    root.draftBarStars = flags.stars === true
    root.editingSettings = true
    Qt.callLater(function () {
      if (!userField) return
      userField.text = root.draftUser
      userField.forceActiveFocus()
      userField.selectAll()
    })
  }

  function cancelEditingSettings() {
    root.editingSettings = false
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function saveSettings() {
    var user = Model.normalizeGithubUser(root.draftUser)
    root.draftUser = user
    root.persistSettings({
      githubUser: user,
      barCount: Model.onOff(root.draftBarCount),
      barViews: Model.onOff(root.draftBarViews),
      barCopies: Model.onOff(root.draftBarCopies),
      barHearts: Model.onOff(root.draftBarHearts),
      barStars: Model.onOff(root.draftBarStars)
    })
    root.editingSettings = false
    Qt.callLater(function () { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function toggleDraftBar(key) {
    if (key === "count") root.draftBarCount = !root.draftBarCount
    else if (key === "views") root.draftBarViews = !root.draftBarViews
    else if (key === "copies") root.draftBarCopies = !root.draftBarCopies
    else if (key === "hearts") root.draftBarHearts = !root.draftBarHearts
    else if (key === "stars") root.draftBarStars = !root.draftBarStars
  }

  function useGuessedUser() {
    root.draftUser = root.guessedUser
    if (userField) userField.text = root.guessedUser
  }

  onRowsChanged: {
    if (root.cursor >= root.rows.length) root.cursor = Math.max(0, root.rows.length - 1)
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function settings(): void { root.openFromHotkey(); root.startEditingSettings() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingSettings
      onMoveRequested: function (dx, dy) { if (!root.editingSettings && dy !== 0) root.moveCursor(dy) }
      onActivateRequested: { if (!root.editingSettings) root.openListing() }
      onReturnRequested: { if (!root.editingSettings) root.startEditingSettings() }
      onCloseRequested: root.editingSettings ? root.cancelEditingSettings() : root.close()
      onTabRequested: function (direction) { if (!root.editingSettings) root.switchPanel(direction) }
      onTextKey: function (text) {
        if (root.editingSettings) return
        if (text === "r") root.refresh()
        else if (text === "o") root.openRepo()
        else if (text === "t") root.cycleSort()
        else if (text === "s") root.startEditingSettings()
        else if (text === "j") root.moveCursor(1)
        else if (text === "k") root.moveCursor(-1)
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        Item {
          width: parent.width
          implicitHeight: Math.max(heroGlyph.implicitHeight, heroLabels.implicitHeight, heroCount.implicitHeight, gearBtn.implicitHeight)

          Text {
            id: heroGlyph
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: Model.glyph.puzzle
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
          }

          Column {
            id: heroLabels
            anchors.left: heroGlyph.right
            anchors.leftMargin: Style.space(14)
            anchors.right: heroCount.visible ? heroCount.left : gearBtn.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "My Plugins"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.editingSettings
                ? "SETTINGS"
                : ((root.owner.githubUser || "set github user") + "  ·  "
                  + Model.sortLabel(Model.sortKey(root.svc ? root.svc.sortMode : "views"))).toUpperCase()
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight

              MouseArea {
                anchors.fill: parent
                enabled: !root.editingSettings
                cursorShape: Qt.PointingHandCursor
                onClicked: root.startEditingSettings()
              }
            }
          }

          Text {
            id: heroCount
            visible: !root.editingSettings
            anchors.right: gearBtn.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            text: String(root.totals.plugins || 0)
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }

          Rectangle {
            id: gearBtn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: settingsLabel.implicitWidth + Style.space(20)
            implicitHeight: Style.space(28)
            width: implicitWidth
            height: implicitHeight
            radius: Style.cornerRadius
            color: gearArea.containsMouse
              ? Style.hoverFillFor(root.fg, root.accent)
              : "transparent"
            border.width: 1
            border.color: root.fg

            Text {
              id: settingsLabel
              anchors.centerIn: parent
              text: root.editingSettings ? "Close" : "Settings"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
            MouseArea {
              id: gearArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.editingSettings ? root.cancelEditingSettings() : root.startEditingSettings()
            }
          }
        }

        Column {
          id: dataView
          visible: !root.editingSettings
          width: parent.width
          spacing: Style.space(12)

        Row {
          width: parent.width
          spacing: Style.space(16)
          visible: root.totals.listed > 0

          Text {
            text: Model.compact(root.totals.views) + "  views"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            text: Model.compact(root.totals.copies) + "  copies"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            text: Model.compact(root.totals.hearts) + "  hearts"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            text: Model.compact(root.totals.stars) + "  stars"
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          visible: root.lastError !== ""
          text: root.lastError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.rows.length === 0
          text: root.fetching
            ? "Loading marketplace…"
            : (root.owner.githubUser
              ? "No marketplace listings for " + root.owner.githubUser + ". Unlisted local plugins show once showUnlisted is on."
              : "No GitHub user yet. Click here, or press s, to set the username.")
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          MouseArea {
            anchors.fill: parent
            enabled: !root.fetching
            cursorShape: Qt.PointingHandCursor
            onClicked: root.startEditingSettings()
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.rows

            Rectangle {
              required property var modelData
              required property int index
              width: column.width
              implicitHeight: rowCol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: index === root.cursor
                ? Style.hoverFillFor(root.fg, root.accent)
                : "transparent"

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onEntered: root.cursor = index
                onClicked: function (mouse) {
                  root.cursor = index
                  if (mouse.button === Qt.RightButton) root.openRepo(modelData)
                  else root.openListing(modelData)
                }
              }

              Column {
                id: rowCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(3)

                Item {
                  width: parent.width
                  implicitHeight: nameText.implicitHeight

                  Text {
                    id: nameText
                    anchors.left: parent.left
                    anchors.right: metaText.left
                    anchors.rightMargin: Style.space(8)
                    text: String(modelData.name || "")
                    color: root.fg
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                  }

                  Text {
                    id: metaText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: {
                      var ver = modelData.version ? "v" + modelData.version : ""
                      var badge = Model.verificationLabel(modelData)
                      return [ver, badge].filter(function (s) { return s !== "" }).join("  ·  ")
                    }
                    color: modelData.listed ? root.dim : (root.bar ? root.bar.urgent : Color.urgent)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                }

                Item {
                  width: parent.width
                  implicitHeight: statsRow.implicitHeight

                  Row {
                    id: statsRow
                    spacing: Style.space(14)
                    Text {
                      text: Model.statText(modelData.views, modelData.listed) + " views"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: Model.statText(modelData.copies, modelData.listed) + " copies"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: Model.statText(modelData.hearts, modelData.listed) + " hearts"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: Model.statText(modelData.stars, modelData.listed) + " stars"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData.listed ? Model.ageText(modelData.listedAt, root.nowMs) : "local"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.rows.length > 0
          text: "Copies are marketplace install-command copies, not installs.  Enter listing  ·  o repo  ·  s settings  ·  t sort  ·  r refresh"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        } // dataView

        Column {
          id: settingsView
          visible: root.editingSettings
          width: parent.width
          spacing: Style.space(14)

          Text {
            width: parent.width
            text: "GITHUB USER"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.guessedUser
              ? ("Plugins on this machine look like they belong to " + root.guessedUser
                + ". Save to pin that, or type a different GitHub username.")
              : "Type the GitHub username whose marketplace listings you want to see."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          TextField {
            id: userField
            width: parent.width
            placeholderText: root.guessedUser ? ("guessed: " + root.guessedUser) : "GitHub username"
            text: root.draftUser
            foreground: root.fg
            font.family: root.fontFamily
            onTextChanged: root.draftUser = text
            Keys.onPressed: function (event) {
              if (event.key === Qt.Key_Escape) { root.cancelEditingSettings(); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.saveSettings(); event.accepted = true }
            }
          }

          Text {
            width: parent.width
            visible: root.guessedUser !== "" && Model.normalizeGithubUser(root.draftUser) !== root.guessedUser
            text: "Use guessed user  " + root.guessedUser
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.useGuessedUser()
            }
          }

          Text {
            width: parent.width
            text: "ON THE BAR"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Pick which totals sit next to the icon. Turning them all off leaves the icon only."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: [
                { key: "count", label: "Count" },
                { key: "views", label: "Views" },
                { key: "copies", label: "Copies" },
                { key: "hearts", label: "Hearts" },
                { key: "stars", label: "Stars" }
              ]

              Rectangle {
                required property var modelData
                readonly property bool active: {
                  var k = String(modelData.key)
                  if (k === "count") return root.draftBarCount
                  if (k === "views") return root.draftBarViews
                  if (k === "copies") return root.draftBarCopies
                  if (k === "hearts") return root.draftBarHearts
                  if (k === "stars") return root.draftBarStars
                  return false
                }
                height: Style.space(28)
                width: barChipLabel.implicitWidth + Style.space(20)
                radius: Style.cornerRadius
                color: active ? root.fg : "transparent"
                border.width: active ? 0 : 1
                border.color: root.fg

                Text {
                  id: barChipLabel
                  anchors.centerIn: parent
                  text: String(modelData.label)
                  color: parent.active ? (root.bar ? root.bar.background : "#101315") : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleDraftBar(modelData.key)
                }
              }
            }
          }

          Row {
            spacing: Style.space(10)

            Rectangle {
              width: saveLabel.implicitWidth + Style.space(28)
              height: Style.space(30)
              radius: Style.cornerRadius
              color: root.fg
              Text {
                id: saveLabel
                anchors.centerIn: parent
                text: "Save"
                color: root.bar ? root.bar.background : "#101315"
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.saveSettings()
              }
            }

            Rectangle {
              width: cancelLabel.implicitWidth + Style.space(28)
              height: Style.space(30)
              radius: Style.cornerRadius
              color: "transparent"
              border.width: 1
              border.color: root.fg
              Text {
                id: cancelLabel
                anchors.centerIn: parent
                text: "Cancel"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cancelEditingSettings()
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Leave the field blank and save to keep auto-detecting from installed plugins. Stored on this widget in ~/.config/omarchy/shell.json."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
