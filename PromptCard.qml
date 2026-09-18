import QtQuick
import qs.Commons
import qs.Ui

// The card that asks what ssh wants to know: a host key to confirm, a password,
// a key passphrase or a plain question. The answer goes straight back to the
// panel, which forwards it over the session FIFO; nothing is kept here beyond
// the text field, which is cleared on every new question.
BorderSurface {
  id: promptCard

  required property var panel
  height: visible ? promptColumn.implicitHeight + Style.spacing.huge * 2 : 0
  radius: Style.cornerRadius
  color: Style.selectedFillFor(panel.fg, Color.accent)
  borderSpec: Border.controlSpec("focus", panel.fg, Color.accent)

  readonly property string type: panel.promptType(panel.prompt)
  readonly property string promptId: panel.prompt ? panel.prompt.id : ""
  // ssh asking for a key's passphrase, or ssh-keygen for the one of a new key
  readonly property string keyFile: panel.prompt ? panel.passphrasePromptKey(panel.prompt.text) : ""
  readonly property bool newKey: !!panel.prompt && panel.newKeyPrompt(panel.prompt.text)
  // A new question never inherits text, visibility or Remember from
  // the previous one (which may have timed out while typing).
  onPromptIdChanged: {
    secretField.text = ""
    revealButton.revealed = false
    rememberSwitch.checked = false
    if (promptId && panel.opened && type !== "hostkey" && type !== "confirm")
      Qt.callLater(function() { secretField.forceActiveFocus() })
  }

  Column {
    id: promptColumn
    x: Style.spacing.huge
    y: Style.spacing.huge
    width: parent.width - Style.spacing.huge * 2
    spacing: Style.spacing.lg

    Row {
      spacing: Style.spacing.lg
      Text {
        textFormat: Text.PlainText
        text: promptCard.type === "hostkey" ? panel.icons.alert : panel.icons.lock
        color: panel.fg
        font.family: panel.ff
        font.pixelSize: Style.font.iconLarge
      }
      Text {
        textFormat: Text.PlainText
        text: panel.promptHeadline(panel.prompt)
        color: panel.fg
        font.family: panel.ff
        font.pixelSize: Style.font.subtitle
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      wrapMode: Text.WrapAnywhere
      text: panel.prompt ? panel.prompt.text.trim() : ""
      color: panel.fg
      font.family: promptCard.type === "hostkey" ? "monospace" : panel.ff
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: promptCard.type === "hostkey"
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Only trust the server if this fingerprint matches the one its administrator gave you (ssh-keygen -lf on the server). It is remembered in ~/.ssh/known_hosts."
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.caption
    }

    // A key passphrase is easily mistaken for the server password.
    Text {
      visible: promptCard.keyFile !== "" || promptCard.newKey
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: promptCard.keyFile !== ""
        ? "This is the passphrase of the key file " + promptCard.keyFile + " on this computer, not the server password. Tick Remember and syncs stop asking for it. Skip key logs in without the key (with the password)."
        : "A new key file is being created. A passphrase protects it on this computer; the next sync asks for it once, and Remember keeps it in the keyring. Leave the field empty for a key without passphrase."
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: panel.promptNote !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: panel.promptNote
      color: Color.urgent
      font.family: panel.ff
      font.pixelSize: Style.font.caption
    }

    Row {
      visible: promptCard.type === "secret" || promptCard.type === "text"
      width: parent.width
      spacing: Style.spacing.md
      TextField {
        id: secretField
        width: parent.width - revealButton.width - parent.spacing
        password: !revealButton.revealed
        inputMethodHints: Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase | Qt.ImhHiddenText
        foreground: panel.fg
        placeholderText: promptCard.type !== "secret" ? "Answer"
          : promptCard.newKey ? "Passphrase for the new key (may stay empty)"
          : promptCard.keyFile !== "" ? "Passphrase of " + panel.fileName(promptCard.keyFile)
          : rememberRow.visible ? "Used for this connection only, unless you tick Remember" : "Used for this connection only, never stored"
        onAccepted: submitButton.clicked()
      }
      PanelActionButton {
        id: revealButton
        property bool revealed: false
        iconText: revealed ? panel.icons.eyeOff : panel.icons.eye
        tooltipText: revealed ? "Hide" : "Show"
        foreground: panel.fg
        fontFamily: panel.ff
        bordered: true
        size: secretField.height
        onClicked: revealed = !revealed
      }
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(rememberRow.implicitHeight, promptButtons.implicitHeight)

      Row {
        id: rememberRow
        visible: promptCard.type === "secret" && panel.rememberable(panel.prompt)
        spacing: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        ToggleSwitch {
          id: rememberSwitch
          checked: false
          foreground: panel.fg
          onToggled: checked = !checked
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          textFormat: Text.PlainText
          text: "Remember in keyring"
          color: panel.fg
          font.family: panel.ff
          font.pixelSize: Style.font.caption
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        id: promptButtons
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.md
        Button {
          text: promptCard.type === "hostkey" ? "Don't connect" : promptCard.keyFile !== "" ? "Skip key" : "Cancel"
          bordered: true
          foreground: panel.fg
          fontFamily: panel.ff
          onClicked: {
            secretField.text = ""
            panel.answerPrompt("", false, false)
          }
        }
        Button {
          id: submitButton
          text: promptCard.type === "hostkey" ? "Trust host" : promptCard.type === "confirm" ? "Allow" : "Continue"
          bordered: true
          active: true
          foreground: panel.fg
          fontFamily: panel.ff
          onClicked: {
            var value = promptCard.type === "hostkey" ? "yes" : promptCard.type === "confirm" ? "" : secretField.text
            secretField.text = ""
            revealButton.revealed = false
            panel.answerPrompt(value, true, rememberRow.visible && rememberSwitch.checked)
            rememberSwitch.checked = false
          }
        }
      }
    }
  }
}
