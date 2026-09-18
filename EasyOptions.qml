import QtQuick
import qs.Commons
import qs.Ui
import "Easy.js" as Easy

// Easy mode questions for the Job tab. Stateless like OptionRow: shows the
// answers read from the job and emits what was clicked; the panel owns the job.
Column {
  id: root

  property var answers: ({ goal: "", skip: {}, extras: [] })
  property string summary: ""
  property bool remote: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal goalPicked(string id)
  signal answered(string key, var value)
  signal openExpert()

  readonly property color dim: Qt.darker(foreground, 1.45)
  spacing: Style.spacing.xl

  component Caption: Text {
    width: parent ? parent.width : 0
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A switch with a title and a plain explanation
  component Choice: Item {
    id: choice
    property string title: ""
    property string hint: ""
    property bool checked: false
    signal toggled()
    implicitHeight: Math.max(choiceText.implicitHeight, choiceSwitch.implicitHeight)
    Column {
      id: choiceText
      width: parent.width - choiceSwitch.width - Style.spacing.xl
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xxs
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: choice.title
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }
      Caption { text: choice.hint; visible: text !== "" }
    }
    ToggleSwitch {
      id: choiceSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: choice.checked
      foreground: root.foreground
      onToggled: choice.toggled()
    }
  }

  // ---- goal
  Column {
    width: parent.width
    spacing: Style.spacing.md
    PanelSectionHeader { text: "WHAT DO YOU WANT TO DO?"; foreground: root.foreground; fontFamily: root.fontFamily }
    Grid {
      id: goals
      width: parent.width
      columns: 2
      columnSpacing: Style.spacing.md
      rowSpacing: Style.spacing.md
      Repeater {
        model: Easy.GOALS
        BorderSurface {
          id: card
          required property var modelData
          readonly property bool selected: root.answers.goal === modelData.id
          width: (goals.width - goals.columnSpacing) / 2
          height: cardColumn.implicitHeight + Style.spacing.lg * 2
          radius: Style.cornerRadius
          color: selected ? Style.selectedFillFor(root.foreground, Color.accent)
            : cardMouse.containsMouse ? Style.hoverFillFor(root.foreground, Color.accent) : "transparent"
          borderSpec: Border.controlSpec(selected ? "focus" : cardMouse.containsMouse ? "hover-cursor" : "normal", root.foreground, Color.accent)
          Column {
            id: cardColumn
            x: Style.spacing.lg
            y: Style.spacing.lg
            width: parent.width - Style.spacing.lg * 2
            spacing: Style.spacing.xxs
            Text {
              textFormat: Text.PlainText
              text: (card.selected ? "● " : "○ ") + card.modelData.label
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
            Caption {
              text: card.modelData.hint
              color: card.modelData.danger && card.selected ? Color.urgent : root.dim
            }
          }
          MouseArea {
            id: cardMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: if (!card.selected) root.goalPicked(card.modelData.id)
          }
        }
      }
    }
    Caption {
      visible: root.answers.goal === "custom"
      text: "Right now none of these: the job uses its own combination of settings from Expert mode. Pick one to replace it."
      color: Color.accent
    }
  }

  // ---- thoroughness
  Column {
    width: parent.width
    spacing: Style.spacing.md
    PanelSectionHeader { text: "HOW CAREFUL?"; foreground: root.foreground; fontFamily: root.fontFamily }
    ButtonGroup {
      focusable: false
      foreground: root.foreground
      fontFamily: root.fontFamily
      value: root.answers.thorough ? "thorough" : "quick"
      options: [{ value: "quick", label: "Quick" }, { value: "thorough", label: "Thorough" }]
      onChanged: function(v) { root.answered("thorough", v === "thorough") }
    }
    Caption {
      text: root.answers.thorough
        ? "Reads every file on both sides and compares the contents. Slow for many or large files, but notices every change."
        : "A file counts as changed when its size or date differs. Fast and right for almost every case."
    }
  }

  // ---- safety and skipping
  Column {
    width: parent.width
    spacing: Style.spacing.lg
    PanelSectionHeader { text: "SAFETY AND WHAT TO LEAVE OUT"; foreground: root.foreground; fontFamily: root.fontFamily }
    Choice {
      width: parent.width
      title: "Keep a safety copy"
      hint: "Files that would be overwritten or deleted at the destination are moved to " + Easy.BACKUP_ROOT + "/<date> there first"
      checked: root.answers.safetyCopy
      onToggled: root.answered("safetyCopy", !root.answers.safetyCopy)
    }
    Repeater {
      model: Easy.SKIP_SETS
      Choice {
        required property var modelData
        width: parent.width
        title: "Skip " + modelData.label.toLowerCase()
        hint: modelData.hint
        checked: !!root.answers.skip[modelData.id]
        onToggled: root.answered("skip." + modelData.id, !root.answers.skip[modelData.id])
      }
    }
  }

  // ---- connection
  Column {
    visible: root.remote
    width: parent.width
    spacing: Style.spacing.lg
    PanelSectionHeader { text: "CONNECTION"; foreground: root.foreground; fontFamily: root.fontFamily }
    Choice {
      width: parent.width
      title: "Slow connection"
      hint: "Compress the data on the way. Helps over the internet, not in a fast home network"
      checked: root.answers.slowLink
      onToggled: root.answered("slowLink", !root.answers.slowLink)
    }
    Choice {
      width: parent.width
      title: "Resume interrupted files"
      hint: "If the connection drops, half-copied files continue where they stopped next time"
      checked: root.answers.resume
      onToggled: root.answered("resume", !root.answers.resume)
    }
    Item {
      width: parent.width
      implicitHeight: Math.max(speedText.implicitHeight, speedGroup.implicitHeight)
      Column {
        id: speedText
        width: parent.width - speedGroup.width - Style.spacing.xl
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs
        Text {
          textFormat: Text.PlainText
          text: "Speed"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
        Caption {
          text: root.answers.bandwidth === "custom" ? "A custom limit is set in Expert mode" : "Leave room so others can still use the internet"
        }
      }
      ButtonGroup {
        id: speedGroup
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        focusable: false
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        value: root.answers.bandwidth
        options: Easy.BANDWIDTH.map(function(b) { return { value: b.id, label: b.label } })
        onChanged: function(v) { root.answered("bandwidth", v) }
      }
    }
  }

  // ---- what will happen
  Column {
    width: parent.width
    spacing: Style.spacing.md
    PanelSectionHeader { text: "WHAT WILL HAPPEN"; foreground: root.foreground; fontFamily: root.fontFamily }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: root.summary
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    Item {
      visible: root.answers.extras.length > 0
      width: parent.width
      implicitHeight: Math.max(extrasText.implicitHeight, expertButton.height)
      Caption {
        id: extrasText
        anchors.left: parent.left
        anchors.right: expertButton.left
        anchors.rightMargin: Style.spacing.lg
        anchors.verticalCenter: parent.verticalCenter
        text: "Also kept from Expert mode: " + root.answers.extras.join(", ")
        color: Color.accent
      }
      Button {
        id: expertButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: "Show in Expert"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        onClicked: root.openExpert()
      }
    }
  }
}
