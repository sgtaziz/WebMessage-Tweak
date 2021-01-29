# WebMessage-Tweak
iOS tweak companion for WebMessage client. Get it through my repo [https://sgtaziz.github.io/repo](https://sgtaziz.github.io/repo)
**To open issues, visit the [client's repo](https://github.com/sgtaziz/WebMessage).**
## Warnings
* This package requires the [client](https://github.com/sgtaziz/WebMessage/releases/latest) installed on your computer to work! Without it, this package will be useless.

* This package has not been tested against iOS 12 fully. It is still in its early stages.
  
## Description
WebMessage is a tweak exposing a REST API (and a WebSocket) from your phone, allowing for SMS and iMessage functionality. To work, the client used and the phone must be on the same network. Alternatively, tunneling can also be used.

The current features are as follows:
* Real-time sending and receiving of messages
* Sending attachments from your computer without needing to transfer it to your phone
* Native notifications
* SSL encryption using your own privately generated certificate
* Password-protected
* Always-running daemon
* Ability to download all attachments through client

More features are planned in the future, such as reactions, read receipts, and more.

If you would like to support my work, you can donate using [this link](https://paypal.me/sgtaziztweaks).

## Build Environment
This package uses [MonkeyDev](https://github.com/AloneMonkey/MonkeyDev/wiki/Installation) for its environment, alongside Theos for the Preferences.
