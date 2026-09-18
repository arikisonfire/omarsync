import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import qs.Commons
import qs.Ui

import "Options.js" as Options

// Log tab: live progress of the running job, the itemised changes filtered by
// kind, and rsync's own messages. The two models are filled by the panel while
// output streams in, so they are handed in rather than owned here.

Item {
  id: logPage

  required property var panel
  required property var itemModel
  required property var logModel
  anchors.fill: parent
  property string kindFilter: ""

  Column {
    id: logHead
    width: parent.width
    spacing: Style.spacing.lg

    Text {
      textFormat: Text.PlainText
      visible: !panel.current
      width: parent.width
      wrapMode: Text.WordWrap
      text: "Nothing has run yet in this session. Start a dry run from the Job tab to preview what would change."
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.body
    }

    Item {
      visible: !!panel.current
      width: parent.width
      implicitHeight: Math.max(logTitle.implicitHeight, stopButton.height)
      Column {
        id: logTitle
        width: parent.width - stopButton.width - Style.spacing.lg
        spacing: Style.spacing.xxs
        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideMiddle
          text: panel.current ? panel.historyTitle(panel.current) : ""
          color: panel.fg
          font.family: panel.ff
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: {
            if (panel.running) {
              var head = panel.current.dry ? "Dry run · nothing is changed" : "Running"
              return head + " · " + panel.runDetail("rate")
            }
            if (!panel.lastStatus) return ""
            var done = panel.lastStatus === "ok"
              ? panel.icons.check + "  " + (panel.current.dry ? "Dry run finished" : "Sync finished")
              : panel.lastStatus === "stopped" ? "Stopped"
              : Options.exitText(panel.lastExit) + " (code " + panel.lastExit + ")" + (panel.current.dry ? " · dry run" : "")
            var parts = [done]
            if (panel.lastStatus === "ok" || panel.lastStatus === "partial")
              parts.push(panel.itemTotal === 1 ? "1 change" : panel.itemTotal + " changes")
            if (panel.runEnd) parts.push(panel.duration(panel.runEnd - panel.current.start))
            return parts.join(" · ")
          }
          color: panel.lastStatus === "failed" ? Color.urgent : panel.lastStatus === "ok" ? panel.fg : panel.dim
          font.bold: panel.lastStatus === "ok"
          font.family: panel.ff
          font.pixelSize: Style.font.caption
        }
      }
      Button {
        id: stopButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: panel.running ? "Stop" : "Back to job"
        iconText: panel.running ? panel.icons.stop : ""
        bordered: true
        foreground: panel.running ? Color.urgent : panel.fg
        fontFamily: panel.ff
        onClicked: panel.running ? panel.stopRun() : (panel.tab = "job")
      }
    }

    // progress bar
    Item {
      visible: !!panel.current
      width: parent.width
      height: Style.space(8)
      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: Style.selectedFillFor(panel.fg, Color.accent)
      }
      Rectangle {
        height: parent.height
        radius: height / 2
        width: parent.width * (panel.running ? panel.shownPercent / 100 : (panel.lastStatus === "ok" ? 1 : panel.shownPercent / 100))
        color: panel.lastStatus === "failed" ? Color.urgent : panel.fg
        Behavior on width { NumberAnimation { duration: 200 } }
      }
    }

    Text {
      visible: !!panel.current && (panel.progress !== null || panel.stats.files !== undefined)
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: {
        var parts = []
        var dry = panel.current && panel.current.dry
        if (panel.progress) parts.push(panel.shownPercent + "%")
        if (panel.progress && !dry) parts.push(panel.progress.bytes + " bytes")
        if (panel.progress && panel.progress.total > 0) parts.push((panel.progress.total - panel.progress.toCheck) + " / " + panel.progress.total + " files checked")
        if (panel.scan && panel.scan.rate) parts.push(panel.scan.rate + " files/s")
        if (panel.stats.files !== undefined) parts.push(panel.stats.files + " files in source")
        if (panel.stats.transferredSize) parts.push(panel.stats.transferredSize + " bytes transferred")
        if (panel.stats.rate) parts.push(panel.stats.rate + " bytes/s")
        return parts.join(" · ")
      }
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.caption
    }

    ButtonGroup {
      visible: !!panel.current
      focusable: false
      foreground: panel.fg
      fontFamily: panel.ff
      fontSize: Style.font.caption
      value: logPage.kindFilter
      options: [
        { value: "", label: "All " + panel.itemTotal },
        { value: "new", label: "New " + (panel.counts["new"] || 0) },
        { value: "update", label: "Updated " + (panel.counts.update || 0) },
        { value: "delete", label: "Deleted " + (panel.counts["delete"] || 0) },
        { value: "attr", label: "Attributes " + (panel.counts.attr || 0) },
        { value: "messages", label: "Messages " + logModel.count }
      ]
      onChanged: function(v) { logPage.kindFilter = v }
    }

    Text {
      readonly property int total: logPage.kindFilter === "" ? panel.itemTotal : (panel.counts[logPage.kindFilter] || 0)
      readonly property int shown: logPage.kindFilter === "" ? itemModel.count : Math.min(total, panel.itemsPerKind)
      visible: !!panel.current && logPage.kindFilter !== "messages" && total > shown
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Showing " + shown + " of " + total + (logPage.kindFilter === "" ? " (up to " + panel.itemsPerKind + " per kind)" : "")
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.caption
    }
  }

  ListView {
    id: itemList
    anchors.top: logHead.bottom
    anchors.topMargin: Style.spacing.lg
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    clip: true
    visible: !!panel.current
    boundsBehavior: Flickable.StopAtBounds
    model: logPage.kindFilter === "messages" ? logModel : itemModel
    QQC.ScrollBar.vertical: QQC.ScrollBar {}
    onCountChanged: if (panel.running && logPage.kindFilter === "messages") positionViewAtEnd()

    delegate: Item {
      required property var model
      width: itemList.width - Style.spacing.xl
      readonly property bool shown: logPage.kindFilter === "messages" || logPage.kindFilter === "" || model.kind === logPage.kindFilter
      height: shown ? lineText.implicitHeight + Style.spacing.xxs : 0
      visible: shown
      Text {
        id: lineText
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: logPage.kindFilter === "messages" ? Text.WrapAnywhere : Text.NoWrap
        elide: logPage.kindFilter === "messages" ? Text.ElideNone : Text.ElideMiddle
        text: logPage.kindFilter === "messages" ? model.text
          : (model.kind === "new" ? "+ " : model.kind === "delete" ? "− " : model.kind === "update" ? "~ " : "  ") + model.path
        color: logPage.kindFilter === "messages" ? (model.error ? Color.urgent : panel.fg)
          : model.kind === "delete" ? Color.urgent : model.kind === "attr" ? panel.dim : panel.fg
        font.family: "monospace"
        font.pixelSize: Style.font.caption
      }
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: itemList.count === 0 && !panel.running && panel.lastStatus !== ""
      text: logPage.kindFilter === "messages" ? "No messages" : "No changes: source and destination are in sync"
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.body
    }
  }
}
