import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    Rectangle {
      anchors.fill: parent
      color: Color.background
      opacity: 0.68
    }

    MouseArea {
      z: 1
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    Rectangle {
      id: securityPanel
      z: 2
      width: Math.min(640, parent.width - 48)
      height: Math.min(370, parent.height - 48)
      anchors.centerIn: parent
      color: Color.lock.background
      border.width: 1
      border.color: root.errorState ? Color.lock.borderError : Color.lock.borderActive
      radius: 2
      clip: true

      Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        color: root.errorState ? Color.lock.borderError : Color.lock.borderActive
      }

      Column {
        id: terminalContent
        width: parent.width - 64
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        spacing: 10

        Text {
          width: parent.width
          text: "RED QUEEN SYSTEM // ACCESS CONTROL"
          color: Color.lock.placeholder
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.caption * 0.95)
          font.letterSpacing: 2
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          text: "HIVE SECURITY SYSTEM"
          color: Color.lock.borderActive
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.display * 0.9)
          font.weight: Font.DemiBold
          font.letterSpacing: 3
          horizontalAlignment: Text.AlignHCenter
        }

        Text {
          width: parent.width
          text: "IDENTITY VERIFICATION REQUIRED"
          color: Color.lock.text
          opacity: 0.82
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.letterSpacing: 1.5
          horizontalAlignment: Text.AlignHCenter
        }

        Item { width: 1; height: 8 }

        BorderSurface {
          id: inputField
          width: Math.min(root.fieldWidth, terminalContent.width)
          height: root.fieldHeight
          anchors.horizontalCenter: parent.horizontalCenter
          color: Color.lock.background
          borderSpec: root.inputBorderSpec
          radius: 1
          clip: true

          TextInput {
            id: passwordInput
            anchors.fill: parent
            anchors.topMargin: inputField.borderTop
            // Reserve the fingerprint icon's width on both sides so the centered
            // dots stay symmetric and never slide under it as they grow.
            anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
            anchors.bottomMargin: inputField.borderBottom
            anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
            verticalAlignment: TextInput.AlignVCenter
            horizontalAlignment: TextInput.AlignHCenter
            activeFocusOnPress: true
            clip: true
            enabled: root.inputEnabled && !root.authenticatingPassword
            readOnly: root.authenticatingPassword
            echoMode: TextInput.Password
            passwordCharacter: "\u25CF"
            passwordMaskDelay: 0
            color: Color.lock.text
            selectionColor: Color.lock.selection
            selectedTextColor: Color.lock.text
            font.family: Style.font.family
            font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
            font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
            cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
            cursorDelegate: Rectangle {
              width: 2
              color: Color.lock.text
              visible: passwordInput.cursorVisible
            }

            onTextChanged: {
              if (!root.syncingPasswordText) root.passwordTextEdited(text)
              if (text.length > 0) {
                root.wakeRequested()
              }
              if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
            }

            onAccepted: {
              var submitted = root.passwordText
              root.passwordTextEdited("")
              if (submitted.length > 0) root.submitPassword(submitted)
            }

            Keys.onPressed: function(event) {
              root.wakeRequested()
              if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
                root.passwordTextEdited("")
                event.accepted = true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.fill: passwordInput
            text: root.authenticatingPassword ? "VERIFYING IDENTITY…" : (root.failureMessage.length > 0 ? "ACCESS DENIED" : "ENTER ACCESS CREDENTIAL")
            visible: passwordInput.text.length === 0
            color: root.authenticatingPassword ? Color.lock.text : (root.failureMessage.length > 0 ? Color.lock.textError : Color.lock.placeholder)
            font.family: Style.font.family
            font.pixelSize: root.fieldFontSize
            font.letterSpacing: 1
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
          }

          // Fingerprint hint pinned inside the field's right edge when a sensor is
          // enrolled, preserving the stock lock's biometric affordance.
          Text {
            id: fingerprintIcon
            objectName: "fingerprintIndicator"
            anchors.right: parent.right
            anchors.rightMargin: inputField.borderRight + 18
            anchors.verticalCenter: parent.verticalCenter
            visible: root.fingerprintConfigured
            text: "󰈷"
            color: Color.lock.placeholder
            font.family: Style.font.family
            font.pixelSize: Math.round(root.fieldFontSize * 1.1)
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
          }
        }

        Text {
          width: parent.width
          height: Style.font.bodySmall + 4
          visible: root.errorState
          text: "AUTHENTICATION FAILURE // ATTEMPT " + String(root.failedAttempts).padStart(2, "0")
          color: Color.lock.textError
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Color.lock.border
          opacity: 0.45
        }

        Row {
          width: parent.width
          spacing: 20

          Text {
            width: (parent.width - parent.spacing) / 2
            text: "SECURITY LINK  //  ACTIVE"
            color: Color.lock.placeholder
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.8
          }

          Text {
            width: (parent.width - parent.spacing) / 2
            text: root.fingerprintConfigured ? "BIOMETRIC  //  ONLINE" : "BIOMETRIC  //  STANDBY"
            color: root.fingerprintConfigured ? Color.lock.text : Color.lock.placeholder
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: 0.8
            horizontalAlignment: Text.AlignRight
          }
        }

        Text {
          width: parent.width
          text: "ENTER TO VERIFY  //  ESC TO CLEAR"
          color: Color.lock.placeholder
          opacity: 0.68
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.letterSpacing: 1
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }

    // Painted only when the surface is created or resized: a low-cost static
    // CRT texture rather than a continuously animated effect.
    Canvas {
      id: scanlines
      z: 3
      anchors.fill: parent
      opacity: 0.12
      renderStrategy: Canvas.Cooperative
      onPaint: {
        var ctx = getContext("2d")
        ctx.clearRect(0, 0, width, height)
        ctx.strokeStyle = "rgba(216, 221, 225, 0.10)"
        ctx.lineWidth = 1
        for (var y = 0.5; y < height; y += 4) {
          ctx.beginPath()
          ctx.moveTo(0, y)
          ctx.lineTo(width, y)
          ctx.stroke()
        }
      }
      onWidthChanged: requestPaint()
      onHeightChanged: requestPaint()
    }
  }
}
