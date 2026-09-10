import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for My Plugins. The popup (Panel.qml) holds the list; the
// headless Service.qml owns fetching and publishes the totals this pill
// reads. Structure mirrors Print Center / Tempest Weather so the bar's
// popout coordinator and hotkey routing behave the same.
BarWidget {
  id: root
  moduleName: "io.github.dreed47.my-plugins"

  readonly property string pluginId: "io.github.dreed47.my-plugins"
  property var service: null

  function resolveService() {
    if (root.service) return
    if (!root.bar || !root.bar.shell) return
    if (typeof root.bar.shell.serviceFor !== "function") return
    var svc = root.bar.shell.serviceFor(root.pluginId)
    if (svc) {
      root.service = svc
      root.injectPanel()
    }
  }

  Timer {
    interval: 500
    running: root.service === null
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveService()
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  onServiceChanged: injectPanel()

  function refresh() {
    if (root.service && root.service.refreshNow) root.service.refreshNow()
    else if (root.service && root.service.refreshIfStale) root.service.refreshIfStale()
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function notify() {
    if (!root.bar || !panelLoader.item) return
    var lines = panelLoader.item.statusLines()
    if (!lines || lines.length === 0) return
    var headline = lines.shift()
    var body = lines.join("\n")
    var cmd = "omarchy-notification-send --app-name 'My Plugins' " + root.bar.shellQuote(headline)
    if (body !== "") cmd += " " + root.bar.shellQuote(body)
    root.bar.run(cmd)
  }

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: button.labelWidth

  onBarChanged: { root.resolveService(); injectPanel() }
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: { root.injectPanel(); Qt.callLater(root.injectPanel) }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    text: panelLoader.item ? panelLoader.item.label : Model.glyph.puzzle
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : "My Plugins"
    Accessible.role: Accessible.Button
    Accessible.name: root.opened ? "Close My Plugins" : "Open My Plugins"

    onPressed: function (b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.notify()
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
