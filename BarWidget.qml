import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Temperature pill: the hottest CPU reading in the bar, a popup listing every
// CPU, GPU and disk sensor, and sound + notification alerts when CPU or GPU
// cross the warning and critical thresholds set in shell.json.
//
//   Left click   open the sensor popup
//   Right click  mute or unmute alerts (persists across restarts)
//   Middle click play the alert sound as a test
BarWidget {
  id: root
  moduleName: "io.github.rafabertholdo.temperature"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---- settings (inline in this widget's shell.json layout entry) ----
  readonly property string labelMode: String(setting("label", "cpu"))
  readonly property int intervalMs: Math.max(1, Number(setting("intervalSec", 3))) * 1000
  readonly property var thresholds: ({
    cpu: { warn: Number(setting("cpuWarn", 80)), critical: Number(setting("cpuCritical", 90)) },
    gpu: { warn: Number(setting("gpuWarn", 85)), critical: Number(setting("gpuCritical", 95)) }
  })
  readonly property bool soundEnabled: setting("sound", true) !== false
  readonly property bool notifyEnabled: setting("notify", true) !== false
  readonly property real volume: Math.max(0, Math.min(1.5, Number(setting("volume", 1.0))))
  readonly property int repeatMs: Math.max(0, Number(setting("repeatSec", 60))) * 1000
  readonly property string warnSound: expandHome(setting("warnSound", "/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"))
  readonly property string criticalSound: expandHome(setting("criticalSound", "/usr/share/sounds/freedesktop/stereo/suspend-error.oga"))

  // Readings must stay over a threshold this many polls in a row before an
  // alert fires, so a one-sample spike from a burst of work stays quiet.
  readonly property int confirmSamples: 2
  // A level clears only once the reading drops this far below its threshold.
  readonly property real hysteresis: 3

  // ---- state ----
  property var sensors: []           // [{ group, label, temp, crit }]
  property var primary: ({})         // group -> °C
  property var levels: ({ cpu: 0, gpu: 0 })   // 0 normal, 1 warn, 2 critical
  property var pending: ({ cpu: 0, gpu: 0 })
  property bool muted: false
  property double snoozeUntil: 0
  property bool popupOpen: false

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy-temperature"
  // The snooze timer below clears snoozeUntil once it passes.
  readonly property bool snoozed: snoozeUntil > 0
  readonly property bool alertsOn: !muted && !snoozed
  readonly property int level: Math.max(levels.cpu || 0, levels.gpu || 0)
  readonly property bool hasReading: primary.cpu !== undefined || primary.gpu !== undefined

  readonly property string glyph: level === 2 ? "\u{f0e01}" : (level === 1 ? "\u{f10c2}" : "\u{f050f}")
  readonly property string barLabel: {
    function deg(v) { return v === undefined ? "–" : Math.round(v) + "°" }
    if (labelMode === "gpu") return deg(primary.gpu)
    if (labelMode === "both") return deg(primary.cpu) + " " + deg(primary.gpu)
    if (labelMode === "max") {
      var m = Math.max(primary.cpu === undefined ? -999 : primary.cpu, primary.gpu === undefined ? -999 : primary.gpu)
      return m === -999 ? "–" : deg(m)
    }
    return deg(primary.cpu !== undefined ? primary.cpu : primary.gpu)
  }

  // Shape the shell routes `omarchy-shell shell toggle|summon|hide <id>` to,
  // so the popup can be bound to a key.
  readonly property bool opened: popupOpen
  function open() { popupOpen = true }
  function close() { popupOpen = false }

  readonly property string iconPath: Qt.resolvedUrl("icon.svg").toString().replace(/^file:\/\//, "")

  // hwmon names a GPU sensor after its driver; show the vendor instead.
  function sensorLabel(label) {
    var names = { nouveau: "NVIDIA (nouveau)", amdgpu: "AMD GPU", radeon: "AMD GPU", i915: "Intel GPU", xe: "Intel GPU" }
    return names[label] || label
  }

  function expandHome(path) {
    var p = String(path || "")
    return p.indexOf("~/") === 0 ? Quickshell.env("HOME") + p.slice(1) : p
  }

  function groupName(g) { return strings.t("group." + g) }

  function statusText(l) {
    return l === 2 ? strings.t("status.hot") : (l === 1 ? strings.t("status.warm") : strings.t("status.normal"))
  }

  function levelColor(l, fallback) {
    if (l === 2) return root.bar ? root.bar.urgent : Commons.Color.urgent
    if (l === 1) return Commons.Color.accent
    return fallback
  }

  function levelFor(group, temp) {
    var t = thresholds[group]
    if (!t || temp === undefined) return 0
    return temp >= t.critical ? 2 : (temp >= t.warn ? 1 : 0)
  }

  // Only the first bar instance (one per monitor) plays sounds and notifies.
  function isAlertOwner() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    return !items || items.length === 0 || items[0] === root
  }

  // ---- reading ----
  function parse(text) {
    var list = []
    var best = ({})
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && i < 128; i++) {
      var f = lines[i].split("\t")
      if (f.length < 4) continue
      var temp = parseInt(f[2], 10) / 1000
      if (!isFinite(temp) || temp < -40 || temp > 200) continue
      var group = f[0]
      var label = String(f[1]).slice(0, 48)
      list.push({ group: group, label: label, temp: temp, crit: parseInt(f[3], 10) / 1000 || 0 })
      // The CPU package / control temperature is the one that matters;
      // otherwise take the hottest sensor in the group.
      var isPackage = /^(Package id|Tctl|Tdie)/.test(label)
      var cur = best[group]
      if (!cur || (isPackage && !cur.pkg) || (isPackage === cur.pkg && temp > cur.temp))
        best[group] = { temp: temp, pkg: isPackage }
    }
    var prim = ({})
    for (var g in best) prim[g] = best[g].temp
    sensors = list
    primary = prim
    evaluate()
  }

  function evaluate() {
    var next = ({ cpu: levels.cpu || 0, gpu: levels.gpu || 0 })
    var pend = ({ cpu: pending.cpu || 0, gpu: pending.gpu || 0 })
    var groups = ["cpu", "gpu"]
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i]
      var temp = primary[g]
      var prev = next[g]
      var raw = levelFor(g, temp)
      var t = thresholds[g]
      if (raw > prev) {
        pend[g] = pend[g] + 1
        if (pend[g] >= confirmSamples) {
          next[g] = raw
          pend[g] = 0
          alert(g, raw, temp)
        }
      } else {
        pend[g] = 0
        if (raw < prev) {
          // Hysteresis: hold the level until the reading is clearly below it.
          if (prev === 2 && temp > t.critical - hysteresis) raw = 2
          else if (raw === 0 && temp > t.warn - hysteresis) raw = 1
          next[g] = raw
        }
      }
    }
    levels = next
    pending = pend
  }

  // ---- alerts ----
  function playSound(path) {
    if (!path) return
    Quickshell.execDetached(["pw-play", "--volume", String(root.volume), path])
  }

  function alert(group, lvl, temp) {
    if (!alertsOn || !isAlertOwner()) return
    if (soundEnabled) playSound(lvl === 2 ? criticalSound : warnSound)
    if (notifyEnabled) {
      var t = thresholds[group]
      var title = strings.t(lvl === 2 ? "notify.criticalTitle" : "notify.warnTitle").arg(groupName(group))
      var body = strings.t("notify.body").arg(Math.round(temp)).arg(t.warn).arg(t.critical)
      Quickshell.execDetached(["notify-send", "-a", strings.t("title"), "-u", lvl === 2 ? "critical" : "normal",
                               "-i", root.iconPath, title, body])
    }
    if (lvl === 2) repeatTimer.restart()
  }

  function setMuted(value) {
    muted = value
    Quickshell.execDetached(["sh", "-c", 'mkdir -p "$1" && printf %s "$2" > "$1/muted"', "sh", stateDir, value ? "1" : "0"])
  }

  function snooze() { snoozeUntil = Date.now() + 3600 * 1000 }
  function resume() { snoozeUntil = 0 }

  // ---- processes and timers ----
  FileView {
    id: muteFile
    path: root.stateDir + "/muted"
    printErrors: false
    onLoaded: root.muted = String(text()).trim() === "1"
  }

  Process {
    id: readProc
    command: [Qt.resolvedUrl("read-temps").toString().replace(/^file:\/\//, "")]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.parse(text) }
  }

  Timer {
    interval: root.intervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!readProc.running) readProc.running = true
  }

  // Keeps nagging while a sensor stays critical.
  Timer {
    id: repeatTimer
    interval: Math.max(1000, root.repeatMs)
    repeat: true
    running: false
    onTriggered: {
      if (root.repeatMs <= 0 || root.level < 2) { stop(); return }
      if (root.alertsOn && root.soundEnabled && root.isAlertOwner()) root.playSound(root.criticalSound)
    }
  }

  Timer {
    interval: 30000
    running: root.snoozeUntil > 0
    repeat: true
    onTriggered: if (root.snoozeUntil <= Date.now()) root.snoozeUntil = 0
  }

  // ---- bar pill ----
  visible: hasReading
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    labelText: root.vertical ? "" : root.barLabel
    slotSize: root.vertical ? Style.bar.statusSlot : Style.bar.statusSlot + labelWidthMetrics.advanceWidth + Style.space(4)
    active: root.level > 0
    activeColor: root.levelColor(root.level, root.bar ? root.bar.barForeground : Commons.Color.foreground)
    dimmed: false
    tooltipText: root.popupOpen ? "" : (function() {
      var parts = []
      if (root.primary.cpu !== undefined) parts.push(strings.t("group.cpu") + " " + Math.round(root.primary.cpu) + "°C")
      if (root.primary.gpu !== undefined) parts.push(strings.t("group.gpu") + " " + Math.round(root.primary.gpu) + "°C")
      var s = parts.join(" · ")
      if (root.muted) s += " (" + strings.t("tooltip.muted") + ")"
      else if (root.snoozed) s += " (" + strings.t("tooltip.snoozed") + ")"
      return s
    })()

    onPressed: function(b) {
      if (b === Qt.RightButton) root.setMuted(!root.muted)
      else if (b === Qt.MiddleButton) root.playSound(root.level === 2 ? root.criticalSound : root.warnSound)
      else root.popupOpen = !root.popupOpen
    }

    TextMetrics {
      id: labelWidthMetrics
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Style.bar.iconFont
      text: root.barLabel
    }
  }

  // ---- popup ----
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
    readonly property string family: root.bar ? root.bar.fontFamily : Style.font.family

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(8)

      // Header: big reading and status word.
      Row {
        width: parent.width
        spacing: Style.space(10)

        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: root.glyph
          color: root.levelColor(root.level, popup.fg)
          font.family: popup.family
          font.pixelSize: Style.font.display
        }

        Column {
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: strings.t("title")
            color: popup.fg
            font.family: popup.family
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            text: root.sensors.length === 0 ? strings.t("status.noSensors") : root.statusText(root.level)
            color: root.levelColor(root.level, Qt.darker(popup.fg, 1.4))
            font.family: popup.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      // One section per sensor group.
      Repeater {
        model: ["cpu", "gpu", "disk"]

        Column {
          id: section
          required property string modelData
          readonly property var rows: root.sensors.filter(function(s) { return s.group === section.modelData })
          readonly property var limits: root.thresholds[modelData] || null
          visible: rows.length > 0
          width: column.width
          spacing: Style.space(4)

          PanelSeparator { width: parent.width; foreground: popup.fg }

          PanelSectionHeader {
            text: root.groupName(section.modelData)
            foreground: popup.fg
            fontFamily: popup.family
          }

          Repeater {
            model: section.rows

            Item {
              id: sensorRow
              required property var modelData
              readonly property int lvl: section.limits ? root.levelFor(section.modelData, modelData.temp) : 0
              readonly property real ceiling: section.limits ? section.limits.critical + 10 : (modelData.crit > 0 ? modelData.crit : 90)
              width: section.width
              height: nameText.implicitHeight + meter.height + Style.space(3)

              Text {
                id: nameText
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: valueText.left
                anchors.rightMargin: Style.space(8)
                text: root.sensorLabel(sensorRow.modelData.label)
                color: popup.fg
                font.family: popup.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }

              Text {
                id: valueText
                textFormat: Text.PlainText
                anchors.right: parent.right
                text: Commons.I18n.formatNumber(Math.round(sensorRow.modelData.temp)) + " °C"
                color: root.levelColor(sensorRow.lvl, popup.fg)
                font.family: popup.family
                font.pixelSize: Style.font.bodySmall
                font.bold: sensorRow.lvl > 0
              }

              Rectangle {
                id: meter
                anchors.bottom: parent.bottom
                width: parent.width
                height: Math.max(2, Style.space(3))
                radius: height / 2
                color: Qt.rgba(popup.fg.r, popup.fg.g, popup.fg.b, 0.12)

                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  width: parent.width * Math.max(0.02, Math.min(1, (sensorRow.modelData.temp - 20) / Math.max(1, sensorRow.ceiling - 20)))
                  color: root.levelColor(sensorRow.lvl, Qt.rgba(popup.fg.r, popup.fg.g, popup.fg.b, 0.55))
                  Behavior on width { NumberAnimation { duration: Style.duration(180); easing.type: Easing.OutCubic } }
                }
              }
            }
          }
        }
      }

      PanelSeparator { width: parent.width; foreground: popup.fg }

      Toggle {
        width: parent.width
        label: strings.t("alerts.label")
        description: root.snoozed
          ? strings.t("alerts.snoozedUntil").arg(Qt.formatTime(new Date(root.snoozeUntil), Qt.locale(Commons.I18n.formatLocale).timeFormat(Locale.ShortFormat)))
          : (root.primary.gpu !== undefined
              ? strings.t("alerts.description").arg(root.thresholds.cpu.warn).arg(root.thresholds.cpu.critical)
                  .arg(root.thresholds.gpu.warn).arg(root.thresholds.gpu.critical)
              : strings.t("alerts.descriptionCpu").arg(root.thresholds.cpu.warn).arg(root.thresholds.cpu.critical))
        foreground: popup.fg
        fontFamily: popup.family
        checked: !root.muted
        onClicked: root.setMuted(!root.muted)
      }

      Row {
        spacing: Style.space(6)

        Button {
          text: strings.t("alerts.test")
          iconText: "\u{f057e}"
          foreground: popup.fg
          bordered: true
          onClicked: root.playSound(root.level === 2 ? root.criticalSound : root.warnSound)
        }

        Button {
          text: root.snoozed ? strings.t("alerts.resume") : strings.t("alerts.snooze")
          iconText: root.snoozed ? "\u{f009a}" : "\u{f009b}"
          foreground: popup.fg
          bordered: true
          enabled: !root.muted
          opacity: enabled ? 1 : 0.4
          onClicked: root.snoozed ? root.resume() : root.snooze()
        }
      }
    }
  }
}
