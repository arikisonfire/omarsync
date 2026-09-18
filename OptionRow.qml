import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Options.js" as Options

// One catalog entry: label, flag and hint on the left, the matching control
// on the right. Stateless: emits edited(value); the panel owns the job.
Item {
  id: root

  required property var def
  property var value
  property bool effective: false      // bool: switch state incl. archive implication
  property bool implied: false        // bool: on only because of --archive
  property bool modified: false
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  signal edited(var value)
  signal browse(string mode)

  readonly property bool wide: def.type === "list" || def.type === "text" || def.type === "path" || def.type === "size"
  readonly property real controlWidth: wide ? width : Math.min(Style.space(230), width * 0.42)
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string flagText: [def.short, def.flag].filter(function(s) { return !!s }).join("  ")
  // The flag sits next to the title when both fit, otherwise it leads the hint.
  readonly property bool flagInline: title.implicitWidth + flagMetrics.width + Style.spacing.md <= labels.width
  TextMetrics { id: flagMetrics; text: root.flagText; font.family: "monospace"; font.pixelSize: Style.font.caption }

  implicitHeight: wide
    ? labels.implicitHeight + Style.spacing.md + loader.implicitHeight + Style.spacing.lg
    : Math.max(labels.implicitHeight, loader.implicitHeight) + Style.spacing.lg

  Rectangle {
    visible: root.modified
    width: Style.space(3)
    height: labels.implicitHeight
    x: -Style.space(9)
    y: Style.spacing.xs
    radius: width / 2
    color: Color.accent
  }

  Column {
    id: labels
    width: root.wide ? root.width : root.width - root.controlWidth - Style.spacing.xl
    spacing: Style.spacing.xxs

    Row {
      spacing: Style.spacing.md
      width: parent.width
      Text {
        id: title
        textFormat: Text.PlainText
        text: root.def.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: Math.min(implicitWidth, parent.width)
      }
      Text {
        id: flag
        textFormat: Text.PlainText
        text: root.flagText
        visible: text !== "" && root.flagInline
        color: root.dim
        font.family: "monospace"
        font.pixelSize: Style.font.caption
        anchors.baseline: title.baseline
      }
    }
    Text {
      textFormat: Text.PlainText
      text: (root.flagText !== "" && !root.flagInline ? root.flagText + " · " : "") + root.def.hint + (root.implied ? " · on via Archive mode" : "")
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
      width: parent.width
    }
  }

  Loader {
    id: loader
    width: root.controlWidth
    x: root.wide ? 0 : root.width - width
    y: root.wide ? labels.implicitHeight + Style.spacing.md : Math.max(0, (labels.implicitHeight - implicitHeight) / 2)
    sourceComponent: {
      switch (root.def.type) {
      case "bool": return boolControl
      case "number": return numberControl
      case "steps": return stepsControl
      case "choice": return choiceControl
      case "list": return listControl
      default: return textControl
      }
    }
  }

  Component {
    id: boolControl
    Item {
      implicitHeight: sw.implicitHeight
      ToggleSwitch {
        id: sw
        anchors.right: parent.right
        checked: root.effective
        foreground: root.foreground
        onToggled: root.edited(!root.effective)
      }
    }
  }

  Component {
    id: numberControl
    Item {
      implicitHeight: nf.implicitHeight
      NumberField {
        id: nf
        anchors.right: parent.right
        fieldWidth: Math.min(Style.space(150), root.controlWidth)
        from: root.def.min !== undefined ? root.def.min : 0
        to: root.def.max !== undefined ? root.def.max : 100000
        value: Number(root.value) || 0
        foreground: root.foreground
        fontFamily: root.fontFamily
        onModified: function(v) { root.edited(v) }
      }
    }
  }

  Component {
    id: stepsControl
    Item {
      implicitHeight: slider.implicitHeight
      readonly property var steps: root.def.steps
      readonly property int index: Math.max(0, steps.indexOf(Number(root.value) || 0))
      PanelSlider {
        id: slider
        width: root.controlWidth - valueLabel.width - Style.spacing.lg
        minimum: 0
        maximum: parent.steps.length - 1
        step: 1
        integer: true
        tickCount: parent.steps.length
        value: parent.index
        fillColor: root.foreground
        knobColor: root.foreground
        trackColor: Style.selectedFillFor(root.foreground, Color.accent)
        onMoved: function(v) { root.edited(parent.steps[Math.round(v)]) }
        onReleased: function(v) { root.edited(parent.steps[Math.round(v)]) }
      }
      Text {
        id: valueLabel
        anchors.right: parent.right
        width: Style.space(70)
        anchors.verticalCenter: slider.verticalCenter
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        readonly property int shown: parent.steps[Math.round(slider.dragging ? slider.liveValue : parent.index)]
        text: root.def.key === "bwlimit" ? Options.formatRate(shown) : (shown === 0 ? "Off" : "-" + "v".repeat(shown))
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  Component {
    id: choiceControl
    Dropdown {
      showLabel: false
      width: root.controlWidth
      foreground: root.foreground
      fontFamily: root.fontFamily
      value: String(root.value || "")
      options: root.def.choices.map(function(c) {
        var label = c === "" ? "Default" : (root.def.key === "ipVersion" ? "IPv" + c : c)
        return { value: c, label: label }
      })
      onChanged: function(v) { root.edited(v) }
    }
  }

  Component {
    id: textControl
    Item {
      implicitHeight: field.implicitHeight
      TextField {
        id: field
        width: root.controlWidth - (browseButton.visible ? browseButton.width + Style.spacing.md : 0)
        text: String(root.value || "")
        placeholderText: root.def.placeholder || (root.def.type === "path" ? "/path" : "")
        foreground: root.foreground
        font.family: root.def.type === "text" || root.def.type === "size" ? "monospace" : root.fontFamily
        onTextEdited: root.edited(text)
      }
      Button {
        id: browseButton
        anchors.right: parent.right
        visible: root.def.type === "path"
        text: "Browse"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        height: field.height
        onClicked: root.browse(root.def.key === "partialDir" || root.def.key === "tempDir" || root.def.key === "backupDir" || root.def.key === "confineRoot" ? "folder" : "file")
      }
    }
  }

  Component {
    id: listControl
    QQC.TextArea {
      id: area
      implicitHeight: Math.max(Style.space(58), contentHeight + topPadding + bottomPadding)
      text: String(root.value || "")
      placeholderText: "One entry per line"
      wrapMode: TextEdit.NoWrap
      color: root.foreground
      placeholderTextColor: Qt.darker(root.foreground, 1.6)
      selectionColor: Style.selectionFillFor(root.foreground, Color.accent)
      font.family: "monospace"
      font.pixelSize: Style.font.body
      padding: Style.spacing.controlPaddingX
      onTextChanged: if (activeFocus) root.edited(text)
      background: BorderSurface {
        color: Style.controlFill(area.activeFocus, area.hovered, root.foreground, Color.accent)
        borderSpec: Border.controlSpec(area.activeFocus ? "focus" : (area.hovered ? "hover-cursor" : "normal"), root.foreground, Color.accent)
        radius: Style.cornerRadius
      }
    }
  }
}
