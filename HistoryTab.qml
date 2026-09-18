import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import qs.Commons
import qs.Ui

import "Locations.js" as Locations

// History tab: every past run with its result, whether its drives are
// connected right now, and the buttons to run it again, load it or copy it.

Flickable {
  id: historyPage

  required property var panel
  anchors.fill: parent
  contentHeight: historyColumn.implicitHeight
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  QQC.ScrollBar.vertical: QQC.ScrollBar { policy: historyPage.contentHeight > historyPage.height ? QQC.ScrollBar.AlwaysOn : QQC.ScrollBar.AlwaysOff }

  Column {
    id: historyColumn
    width: historyPage.width - Style.spacing.xl
    spacing: Style.spacing.md

    Item {
      width: parent.width
      implicitHeight: clearHistory.height
      PanelSectionHeader {
        text: panel.history.length ? panel.history.length + " PAST RUNS" : "PAST RUNS"
        foreground: panel.fg
        fontFamily: panel.ff
        anchors.verticalCenter: parent.verticalCenter
      }
      Button {
        id: clearHistory
        property bool armed: false
        anchors.right: parent.right
        visible: panel.history.length > 0
        text: armed ? "Click again to clear" : "Clear history"
        bordered: true
        foreground: armed ? Color.urgent : panel.fg
        fontFamily: panel.ff
        fontSize: Style.font.caption
        onClicked: {
          if (!armed) { armed = true; disarm.restart(); return }
          armed = false
          panel.history = []
          panel.saveHistory()
        }
        Timer { id: disarm; interval: 4000; onTriggered: clearHistory.armed = false }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: panel.history.length === 0
      width: parent.width
      wrapMode: Text.WordWrap
      text: "Every sync and dry run shows up here with its source, destination, options and result, ready to run again."
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.body
    }

    Repeater {
      model: panel.history
      BorderSurface {
        id: historyRow
        required property var modelData
        width: historyColumn.width
        height: rowColumn.implicitHeight + Style.spacing.lg * 2
        radius: Style.cornerRadius
        color: rowHover.hovered ? Style.hoverFillFor(panel.fg, Color.accent) : Style.normalFillFor(panel.fg, Color.accent, Color.urgent)
        borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)

        readonly property var srcState: Locations.describe(modelData.job.src, modelData.job.srcAnchor, panel.mounts, panel.home)
        readonly property var dstState: Locations.describe(modelData.job.dst, modelData.job.dstAnchor, panel.mounts, panel.home)
        readonly property bool available: srcState.connected && dstState.connected

        HoverHandler { id: rowHover }

        Column {
          id: rowColumn
          x: Style.spacing.xl
          y: Style.spacing.lg
          width: parent.width - Style.spacing.xl * 2
          spacing: Style.spacing.sm

          Row {
            width: parent.width
            spacing: Style.spacing.md
            Rectangle {
              width: Style.space(8); height: width; radius: width / 2
              color: panel.statusColor(historyRow.modelData.status)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              width: parent.width - Style.space(20)
              elide: Text.ElideMiddle
              text: panel.historyTitle(historyRow.modelData)
              color: panel.fg
              font.family: panel.ff
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            elide: Text.ElideRight
            text: panel.relativeTime(historyRow.modelData.start) + " · " + panel.duration(historyRow.modelData.end - historyRow.modelData.start)
              + (historyRow.modelData.dry ? " · dry run" : "") + " · " + panel.historySummary(historyRow.modelData)
            color: panel.statusColor(historyRow.modelData.status) === panel.fg ? panel.dim : panel.statusColor(historyRow.modelData.status)
            font.family: panel.ff
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: !historyRow.available
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: panel.icons.drive + "  " + [historyRow.srcState, historyRow.dstState].filter(function(s) { return !s.connected }).map(function(s) { return s.title }).join(", ") + " not connected"
            color: Color.urgent
            font.family: panel.ff
            font.pixelSize: Style.font.caption
          }
          Flow {
            width: parent.width
            spacing: Style.spacing.md
            topPadding: Style.spacing.xs
            Button {
              text: panel.confirmRerun === historyRow.modelData.id
                ? (historyRow.modelData.dry ? "Confirm dry run" : "Confirm: run now")
                : (historyRow.modelData.dry ? "Dry run again" : "Run again")
              iconText: panel.icons.play
              bordered: true
              active: panel.confirmRerun === historyRow.modelData.id
              enabled: historyRow.available && !panel.busy
              opacity: enabled ? 1 : 0.45
              foreground: panel.fg
              fontFamily: panel.ff
              fontSize: Style.font.caption
              onClicked: panel.rerun(historyRow.modelData)
            }
            Button {
              text: "Load"
              tooltipText: "Open this job in the Job tab"
              bordered: true
              foreground: panel.fg
              fontFamily: panel.ff
              fontSize: Style.font.caption
              onClicked: { panel.loadJob(historyRow.modelData.job); panel.profileName = ""; panel.tab = "job" }
            }
            Button {
              text: "Copy command"
              bordered: true
              foreground: panel.fg
              fontFamily: panel.ff
              fontSize: Style.font.caption
              onClicked: { Quickshell.execDetached(["wl-copy", "--", historyRow.modelData.command || ""]); panel.flash("Command copied") }
            }
            Button {
              text: "Remove"
              bordered: true
              foreground: panel.fg
              fontFamily: panel.ff
              fontSize: Style.font.caption
              onClicked: panel.deleteHistory(historyRow.modelData.id)
            }
          }
        }
      }
    }
  }
}
