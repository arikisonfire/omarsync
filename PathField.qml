import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Source or destination: text field, browse buttons, a quick-pick menu
// (recent locations, connected drives, SSH hosts) and a line describing where
// the path lives.
Column {
  id: root

  property string title: ""
  property string path: ""
  property var info: ({ kind: "none", title: "", detail: "", connected: true })
  property var choices: []           // [{ icon, label, detail }]
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property var icons: ({})

  signal edited(string text)
  signal picked(int index)
  signal browse(string mode)

  readonly property color dim: Qt.darker(foreground, 1.45)
  spacing: Style.spacing.md

  PanelSectionHeader {
    text: root.title
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Row {
    width: parent.width
    spacing: Style.spacing.md

    TextField {
      id: field
      width: parent.width - (folderButton.width + fileButton.width + pickButton.width + parent.spacing * 3)
      text: root.path
      placeholderText: "/path/to/folder/  ·  user@host:/path  ·  rsync://host/module"
      foreground: root.foreground
      font.family: root.fontFamily
      onTextEdited: root.edited(text)
    }
    PanelActionButton {
      id: folderButton
      iconText: root.icons.folder
      tooltipText: "Choose folder"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      size: field.height
      onClicked: root.browse("folder")
    }
    PanelActionButton {
      id: fileButton
      iconText: root.icons.file
      tooltipText: "Choose file"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      size: field.height
      onClicked: root.browse("file")
    }
    PanelActionButton {
      id: pickButton
      iconText: root.icons.history
      tooltipText: root.choices.length ? "Recent locations, drives and SSH hosts" : "Nothing recent yet"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      size: field.height
      enabled: root.choices.length > 0
      opacity: enabled ? 1 : 0.4
      onClicked: menu.opened ? menu.close() : menu.open()

      QQC.Popup {
        id: menu
        x: pickButton.width - width
        y: pickButton.height + Style.spacing.xxs
        width: Math.min(Style.space(460), root.width)
        height: Math.min(list.contentHeight, Style.space(300)) + topPadding + bottomPadding
        padding: Style.spacing.xs
        focus: true
        background: BorderSurface {
          color: Color.popups.background
          borderSpec: Border.localOrSurfaceSpec("popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)
          radius: Style.cornerRadius
        }
        contentItem: ListView {
          id: list
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.choices
          delegate: Rectangle {
            required property var modelData
            required property int index
            width: list.width
            height: Math.max(Style.spacing.popupRowHeight, rowText.implicitHeight + Style.spacing.md)
            color: rowMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
            radius: Style.cornerRadius

            Text {
              textFormat: Text.PlainText
              id: rowIcon
              anchors.left: parent.left
              anchors.leftMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              text: modelData.icon || ""
              color: modelData.disabled ? root.dim : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.icon
              width: Style.space(22)
            }
            Column {
              id: rowText
              anchors.left: rowIcon.right
              anchors.right: parent.right
              anchors.rightMargin: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              Text {
                textFormat: Text.PlainText
                text: modelData.label
                width: parent.width
                elide: Text.ElideMiddle
                color: modelData.disabled ? root.dim : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                visible: !!modelData.detail
                text: modelData.detail || ""
                width: parent.width
                elide: Text.ElideRight
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { menu.close(); root.picked(index) }
            }
          }
        }
      }
    }
  }

  Row {
    visible: root.info.kind !== "none"
    spacing: Style.spacing.md
    width: parent.width

    Text {
      textFormat: Text.PlainText
      text: root.info.kind === "drive" ? root.icons.drive
        : root.info.kind === "ssh" || root.info.kind === "daemon" ? root.icons.server : root.icons.laptop
      color: root.info.connected ? root.foreground : Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - Style.space(24)
      elide: Text.ElideMiddle
      text: root.info.title + (root.info.kind === "local" ? "" : " · " + root.info.detail)
        + (root.info.connected ? "" : " · not connected")
      color: root.info.connected ? root.dim : Color.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: !root.info.connected
    }
  }
}
