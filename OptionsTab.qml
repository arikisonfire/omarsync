import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

import "Options.js" as Options

// Options tab: the whole rsync catalog, grouped and searchable, plus the free
// "extra arguments" field. Every row writes straight into `panel.job.opts`.

Item {
  anchors.fill: parent

  property string search: ""
  property bool modifiedOnly: false
  property var expanded: ({})
  id: optionsPage

  required property var panel

  Row {
    id: optionsBar
    width: parent.width
    spacing: Style.spacing.lg
    TextField {
      id: searchField
      width: parent.width - modifiedRow.width - resetButton.width - parent.spacing * 2
      placeholderText: panel.icons.search + "  Search " + Options.CATALOG.length + " options (name, flag or description)"
      foreground: panel.fg
      onTextEdited: optionsPage.search = text
    }
    Row {
      id: modifiedRow
      spacing: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      ToggleSwitch {
        checked: optionsPage.modifiedOnly
        foreground: panel.fg
        onToggled: optionsPage.modifiedOnly = !optionsPage.modifiedOnly
        anchors.verticalCenter: parent.verticalCenter
      }
      Text {
        textFormat: Text.PlainText
        text: "Changed"
        color: panel.fg
        font.family: panel.ff
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }
    }
    Button {
      id: resetButton
      text: "Reset"
      tooltipText: "Back to Archive mode only"
      bordered: true
      foreground: panel.fg
      fontFamily: panel.ff
      fontSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
      onClicked: panel.patchJob({ opts: { archive: true }, extra: "" })
    }
  }

  Flickable {
    id: optionsFlick
    anchors.top: optionsBar.bottom
    anchors.topMargin: Style.spacing.lg
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    contentHeight: optionsColumn.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    QQC.ScrollBar.vertical: QQC.ScrollBar { policy: optionsFlick.contentHeight > optionsFlick.height ? QQC.ScrollBar.AlwaysOn : QQC.ScrollBar.AlwaysOff }

    Column {
      id: optionsColumn
      x: Style.space(10)
      width: optionsFlick.width - Style.space(24)
      spacing: Style.spacing.md

      Repeater {
        model: Options.GROUPS
        Column {
          id: groupColumn
          required property var modelData
          width: optionsColumn.width
          spacing: Style.spacing.sm

          readonly property var defs: Options.CATALOG.filter(function(d) {
            if (d.group !== modelData.id) return false
            if (optionsPage.modifiedOnly && !Options.isModified(panel.job.opts, d.key)) return false
            var q = optionsPage.search.trim().toLowerCase()
            if (!q) return true
            return (d.label + " " + d.flag + " " + d.short + " " + d.hint).toLowerCase().indexOf(q) >= 0
          })
          readonly property int changed: Options.CATALOG.filter(function(d) { return d.group === modelData.id && Options.isModified(panel.job.opts, d.key) }).length
          readonly property bool open: optionsPage.search.trim() !== "" || optionsPage.modifiedOnly || optionsPage.expanded[modelData.id] === true
          visible: defs.length > 0

          Rectangle {
            width: parent.width
            height: groupHeader.implicitHeight + Style.spacing.md * 2
            radius: Style.cornerRadius
            color: groupMouse.containsMouse ? Style.hoverFillFor(panel.fg, Color.accent) : Style.normalFillFor(panel.fg, Color.accent, Color.urgent)
            Row {
              id: groupHeader
              x: Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.spacing.lg
              Text {
                textFormat: Text.PlainText
                text: groupColumn.open ? panel.icons.chevronDown : panel.icons.chevronRight
                color: panel.fg
                font.family: panel.ff
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                text: groupColumn.modelData.label
                color: panel.fg
                font.family: panel.ff
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                textFormat: Text.PlainText
                text: groupColumn.defs.length + " options" + (groupColumn.changed ? " · " + groupColumn.changed + " changed" : "")
                color: groupColumn.changed ? Color.accent : panel.dim
                font.family: panel.ff
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }
            }
            MouseArea {
              id: groupMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                var e = Object.assign({}, optionsPage.expanded)
                e[groupColumn.modelData.id] = !(e[groupColumn.modelData.id] === true)
                optionsPage.expanded = e
              }
            }
          }

          Column {
            visible: groupColumn.open
            width: parent.width
            spacing: Style.spacing.xs
            topPadding: Style.spacing.md
            Repeater {
              model: groupColumn.open ? groupColumn.defs : []
              OptionRow {
                required property var modelData
                width: optionsColumn.width
                def: modelData
                value: panel.job.opts[modelData.key]
                effective: Options.isOn(panel.job.opts, modelData.key)
                implied: Options.impliedByArchive(panel.job.opts, modelData.key) && panel.job.opts[modelData.key] === undefined
                modified: Options.isModified(panel.job.opts, modelData.key)
                foreground: panel.fg
                fontFamily: panel.ff
                onEdited: function(v) { panel.setOpt(modelData.key, v) }
                onBrowse: function(mode) { panel.browse(modelData.key, mode) }
              }
            }
          }
        }
      }

      // extra arguments
      Column {
        width: parent.width
        spacing: Style.spacing.md
        topPadding: Style.spacing.lg
        PanelSectionHeader { text: "EXTRA ARGUMENTS"; foreground: panel.fg; fontFamily: panel.ff }
        TextField {
          width: parent.width
          text: panel.job.extra
          placeholderText: "Anything else, quoted like in a shell (not run through a shell)"
          foreground: panel.fg
          font.family: "monospace"
          onTextEdited: panel.patchJob({ extra: text })
        }
      }
      Item { width: 1; height: Style.spacing.xl }
    }
  }
}
