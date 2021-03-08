//
//  TelegraphDemo.swift
//  Telegraph Examples
//
//  Created by Yvo van Beek on 5/17/17.
//  Copyright © 2017 Building42. All rights reserved.
//

import Foundation
import Telegraph
import SQLite
import SwiftyJSON
import UIKit
import AVKit

public class WebMessageServer: NSObject {
  var identity: CertificateIdentity?
  var caCertificate: Certificate?
  var tlsPolicy: TLSPolicy?
  var db: Connection?
  var contactsDB: Connection?
  var imageDB: Connection?
  var server: Server!
  var webSocketClient: WebSocketClient!
  var port: Int!
  var enableSSL: Bool!
  var sender: IPCSender = IPCSender.init()
  var watcher: IPCWatcher!
  var clients: [WebSocket] = []
  var payloadData: Data = Data.init()
}

public extension WebMessageServer {
  func start() {
    port = 8180
    enableSSL = true
    
    if let dict = NSDictionary(contentsOfFile: "/User/Library/Preferences/com.sgtaziz.webmessage.plist") {
      if let portDic = dict["port"] as? String {
        let portInt = Int(portDic) ?? 8180
        port = portInt
      }
      if let sslDict = dict["ssl"] as? String {
        enableSSL = sslDict == "1"
      }
    }
    
    loadCertificates()

    // Create and start the server
    setupServer()
    
    db = try! Connection("/var/mobile/Library/SMS/sms.db")
    contactsDB = try! Connection("/private/var/mobile/Library/AddressBook/AddressBook.sqlitedb")
    imageDB = try! Connection("/private/var/mobile/Library/AddressBook/AddressBookImages.sqlitedb")
    
//    db!.trace { print($0) }
  }
  
  func stop() {
    server.stop(immediately: true)
    exit(0)
  }
}

extension WebMessageServer {
  private func loadCertificates() {
    
    if let passphraseURL = URL(string: "file:///Library/Application%20Support/WebMessage/passphrase") {
       do {
        let passphrase = try String(contentsOf: passphraseURL).trimmingCharacters(in: .whitespacesAndNewlines)

        // Load the P12 identity package from the bundle
        if let identityURL = URL(string: "file:///Library/Application%20Support/WebMessage/webmessage.p12") {
          identity = CertificateIdentity(p12URL: identityURL, passphrase: passphrase)
        }

        // Load the Certificate Authority certificate from the bundle
        if let caCertificateURL = URL(string: "file:///Library/Application%20Support/WebMessage/webmessage.der") {
          caCertificate = Certificate(derURL: caCertificateURL)
        }
       } catch {}
    }
  }
  
  private func loadHooks() {
    watcher.setTexts = { value in
      if self.clients.count == 0 {
        return
      }
      
      if let value = value {
        self.getTextByGUID(guid: value)
      }
    }
    
    watcher.stopWebserver = { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: {
        self.stop()
      })
    }
    
    watcher.setMessageAsRead = { args in
      if self.clients.count == 0 {
        return
      }
      
      let json = try! JSON(["action": "setAsRead", "data": args as Any]).rawData()
      
      for client in self.clients {
        client.send(data: json)
      }
    }
    
    watcher.removeChat = { chatId in
      if self.clients.count == 0 {
        return
      }
      
      let json = try! JSON(["action": "removeChat", "data": ["chatId": chatId]]).rawData()
      
      for client in self.clients {
        client.send(data: json)
      }
    }
    
    watcher.setTypingIndicator = { args in
      if self.clients.count == 0 {
        return
      }
      
      let json = try! JSON(["action": "setTypingIndicator", "data": args as Any]).rawData()
      
      for client in self.clients {
        client.send(data: json)
      }
    }
  }

  private func setupServer() {
    // Create the server instance
    if enableSSL, let identity = identity, let caCertificate = caCertificate {
      server = Server(identity: identity, caCertificates: [caCertificate])
    } else {
      server = Server()
    }

    // Set the delegates and a low web socket ping interval to demonstrate ping-pong
    server.delegate = self
    server.webSocketDelegate = self

    // Define routes
    server.route(.GET, "attachments(/)", serverHandleAttachments)
    server.route(.GET, "contactimg(/)", serverHandleContactImage)
    server.route(.GET, "search(/)", serverHandleSearchContacts)
    server.route(.GET, "stopServer(/)", serverHandleStopServer)
    server.route(.POST, "sendText(/)", serverHandleSendText)
    server.route(.OPTIONS, "*") { .ok } // Browsers send an OPTIONS request to check for CORS before requesting
    
    server.serveBundle(.main, "/")

    // Handle up to 3 requests simultaneously. This value is to ensure light resource usage on device
    server.concurrency = 3
    
    server.httpConfig.requestHandlers.insert(HTTPCORSHandler(), at: 0)
    server.httpConfig.requestHandlers.insert(HTTPAuthHandler(), at: 1)
    server.httpConfig.requestHandlers.insert(HTTPRequestParamsHandler(), at: 2)

    do {
      try server.start(port: port)
      watcher = IPCWatcher.sharedInstance()
      loadHooks()
      
      //Send a "fake" first text, since first text is never actually sent?
//      _ = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { timer in
//        self.sender.sendFakeText()
//      }
    } catch {
      print("[SERVER]", "Port is in use.")
      exit(0)
    }

    print("[SERVER]", "Server is running - url:", serverURL())
  }
}
// MARK: - Server HTTP middleware

public class HTTPCORSHandler: HTTPRequestHandler {
  public func respond(to request: HTTPRequest, nextHandler: HTTPRequest.Handler) throws -> HTTPResponse? {
    let response = try nextHandler(request)
    response!.headers.accessControlAllowOrigin = "*"
    response!.headers.accessControlAllowMethods = "*"
    response!.headers.accessControlAllowHeaders = "*"
    return response
  }
}

public class HTTPAuthHandler: HTTPRequestHandler {
  public func respond(to request: HTTPRequest, nextHandler: HTTPRequest.Handler) throws -> HTTPResponse? {
    if (request.method == HTTPMethod.OPTIONS) {
      return try nextHandler(request)
    }
    
    var password = ""
    var auth = request.headers.authorization ?? ""
    
    request.uri.queryItems?.forEach { item in
      if item.name == "auth" {
        auth = item.value ?? ""
      }
    }
    
    if let dict = NSDictionary(contentsOfFile: "/User/Library/Preferences/com.sgtaziz.webmessage.plist") {
      if let passwordDict = dict["password"] as? String {
        password = passwordDict
      }
    }
    
    if auth != password {
      print("[SERVER]", "Incorrect password:", auth)
      return HTTPResponse(.forbidden)
    }
    
    return try nextHandler(request)
  }
}

public class HTTPRequestParamsHandler: HTTPRequestHandler {
  public func respond(to request: HTTPRequest, nextHandler: HTTPRequest.Handler) throws -> HTTPResponse? {
    // Extract the QueryString items and put them in the HTTPRequest params
    request.uri.queryItems?.forEach { item in
      request.params[item.name] = item.value
    }

    // Continue with the rest of the handlers
    return try nextHandler(request)
  }
}
// MARK: - WebSocket Delegate

extension WebMessageServer: ServerWebSocketDelegate {
  /// Raised when a web socket client connects to the server.
  public func server(_ server: Server, webSocketDidConnect webSocket: WebSocket, handshake: HTTPRequest) {
    print("[SERVER]", "Client connected to WebSocket")
    clients.append(webSocket)
  }

  /// Raised when a web socket client disconnects from the server.
  public func server(_ server: Server, webSocketDidDisconnect webSocket: WebSocket, error: Error?) {
    clients.removeAll(where: {$0.remoteEndpoint == webSocket.remoteEndpoint})
  }

  /// Raised when the server receives a web socket message.
  public func server(_ server: Server, webSocket: WebSocket, didReceiveMessage message: WebSocketMessage) {
    
    if let fragmentedData = message.payload.data {
      var data: Data!
      if (!message.finBit) {
        payloadData.append(fragmentedData)
        return
      } else if (payloadData.isEmpty) {
        data = fragmentedData
      } else {
        payloadData.append(fragmentedData)
        data = payloadData
      }
      
      do {
        let json = try JSON(data: data)
        
        switch json["action"] {
          case "fetchChats":
            serverHandleChats(webSocket: webSocket, data: json["data"])
          case "fetchMessages":
            serverHandleMessages(webSocket: webSocket, data: json["data"])
          case "deleteChat":
            sender.deleteChat(json["data"]["chatId"].string ?? "")
          case "markAsRead":
            let chat_id = json["data"]["chatId"].string ?? ""
            if chat_id != "" {
              sender.setAsRead(chat_id)
            }
          case "sendReaction":
            let chat_id = json["data"]["chatId"].string ?? ""
            let guid = json["data"]["guid"].string ?? ""
            let reactionId = json["data"]["reactionId"].number ?? 0
            let part = json["data"]["part"].number ?? 0
            
            if (reactionId.int32Value >= 2000 && guid != "") {
              sender.sendReaction(reactionId, forGuid: guid, forChatId: chat_id, forPart: part)
            }
          case "setIsLocallyTyping":
            let chat_id = json["data"]["chatId"].string ?? ""
            let isTyping = json["data"]["typing"].bool ?? false
            
            if (chat_id != "") {
              sender.setIsLocallyTyping(isTyping, forChatId: chat_id)
            }
          case "getMessageByGUID":
            let guid = json["data"]["guid"].string ?? ""
            getTextByGUID(guid: guid, webSocket: webSocket)
          default:
            print("[SERVER]", "Received unknown payload:", message.payload)
        }
      } catch {
//        print("[SERVER]", "Received non-JSON payload:", message.payload.data!)
//        print("[SERVER]", "Opcode is: ", message.opcode)
      }
    }
    
    payloadData = Data.init()
  }
}

// MARK: - Server route handlers

extension WebMessageServer {
  private func serverHandleStopServer(request: HTTPRequest) -> HTTPResponse {
    self.stop()
    return HTTPResponse(.ok)
  }
  
  private func serverHandleSendText(request: HTTPRequest) -> HTTPResponse {
    let data = try? JSON(data: request.body)
    if let data = data {
      let text: String = data["text"].string ?? ""
      let address: String = data["address"].string ?? ""
      let subject: String = data["subject"].string ?? ""
      var attachments: [[String:Any]] = [[String:Any]]()
      
      for attachment in data["attachments"].array ?? [] {
        if let name = attachment["name"].string, let data = attachment["data"].string {
          var attachmentobj : [String:Any] = [String:Any]()
          
          attachmentobj["name"] = name
          attachmentobj["data"] = data
          attachments.append(attachmentobj)
        }
      }
      
      if (text != "" || attachments.count > 0) && address != "" {
        sender.sendText(text, withSubject: subject, toAddress: address, withAttachments: attachments)
        return HTTPResponse(.ok)
      }
    }
    
    return HTTPResponse(.badRequest)
  }
  
  private func serverHandleChats(webSocket: WebSocket, data: JSON) {
    let chats = try! db!.prepare("""
        SELECT CMJ.chat_id, chat_identifier, text, cache_has_attachments, max(message."date"),
               last_read_message_timestamp, is_from_me, item_type, is_read,
               associated_message_guid, handle.id FROM "chat"
        INNER JOIN "chat_message_join" AS CMJ ON (CMJ."chat_id" = "chat"."ROWID")
        INNER JOIN "message" ON ("message"."ROWID" = "message_id")
        INNER JOIN "chat_handle_join" AS CHJ ON (CHJ."chat_id" = chat.ROWID)
        LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
        WHERE text NOT NULL
        GROUP BY chat_identifier
        ORDER BY "message"."date" DESC
        LIMIT ? OFFSET ?
      """)
    
    var chatsJson : [[String:Any]] = [[String:Any]]()
    for chat in try! chats.run(data["limit"].string ?? "25", data["offset"].string ?? "0") {
      var chatJson : [String:Any] = [String:Any]()
      
      let contactData = getDisplayName(chat_id: chat[1] as? String ?? "")
      
      chatJson["id"] = chat[0]!
      chatJson["author"] = contactData[0]
      chatJson["docid"] = contactData[1]
      
      if chat[9] != nil {
        let authorName = chat[10] != nil ? getDisplayName(chat_id: chat[10] as? String ?? "")[0] as! String : ""
        let textContent = chat[2] as? String ?? ""
        let authorPreview = (chat[6] as! Int64 == 1) ? "You" : String(authorName.split(separator: " ")[0])
        chatJson["text"] = authorPreview + " " + String(textContent.prefix(1)).lowercased() + textContent.dropFirst()
      } else {
        chatJson["text"] = chat[2] ?? ""
      }
      
      chatJson["attachment"] = chat[3]!
      chatJson["date"] = (chat[4] as! Int64 + 978307200000000000) / 1000000
      chatJson["read"] = chat[5] as! Int64 > chat[4] as! Int64 || chat[6] as! Int64 == 1 || chat[7] as! Int64 != 0 || chat[8] as! Int64 == 1
      chatJson["address"] = chat[1]!
      chatJson["personId"] = chatJson["address"]
      
      chatsJson.append(chatJson)
    }
    
    let json = try! JSON(["action":"fetchChats", "data":chatsJson]).rawData()
    webSocket.send(data: json)
  }
  
  private func serverHandleMessages(webSocket: WebSocket, data: JSON) {
    let id = data["id"].string ?? "0"
    let messages = try! db!.prepare("""
        SELECT message_id, service_name, text, date, is_from_me, cache_has_attachments, chat.room_name,
               chat_identifier, handle.id, date_delivered, date_read, message.guid, subject, payload_data, balloon_bundle_id FROM "message"
        INNER JOIN "chat_message_join" AS CMJ ON ("message_id" = "message"."ROWID")
        LEFT JOIN "chat" ON ("chat"."ROWID" = CMJ."chat_id")
        LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
        WHERE chat.chat_identifier = ?
        AND associated_message_guid IS NULL
        ORDER BY "message"."date" DESC
        LIMIT ? OFFSET ?
      """)
    
    var messagesJson : [[String:Any]] = [[String:Any]]()
    
    for message in try! messages.run(id, data["limit"].string ?? "25", data["offset"].string ?? "0") {
      var messageJson : [String:Any] = [String:Any]()
      var attachments: [[String]] = []
      
      let contactData = getDisplayName(chat_id: message[7] as? String ?? "")
      messageJson["name"] = contactData[0]
      messageJson["docid"] = contactData[1]
      
      let authorData = getDisplayName(chat_id: message[8] as? String ?? "")
      
      if (message[5] as! Int64 == 1) {
        attachments = getAttachments(mid: message[0] as! Int64)
      }
      
      messageJson["id"] = message[0]!
      messageJson["type"] = message[1]!
      messageJson["text"] = message[2] ?? ""
      messageJson["date"] = (message[3] as! Int64 + 978307200000000000) / 1000000
      messageJson["sender"] = message[4]!
      messageJson["attachments"] = attachments
      messageJson["group"] = message[6] ?? nil
      messageJson["chatId"] = message[7]!
      messageJson["author"] = authorData[0]
      messageJson["authorDocid"] = authorData[1]
      messageJson["dateDelivered"] = message[9] as! Int64 == 0 ? 0 : ((message[9] as! Int64 + 978307200000000000) / 1000000)
      messageJson["dateRead"] = message[10] as! Int64 == 0 ? 0 : ((message[10] as! Int64 + 978307200000000000) / 1000000)
      messageJson["guid"] = message[11] ?? ""
      messageJson["personId"] = messageJson["chatId"]
      messageJson["subject"] = message[12] ?? nil
      if let payloadData = message[13] as? SQLite.Blob {
        messageJson["payload"] = Data.fromDatatypeValue(payloadData).base64EncodedString()
      }
      messageJson["balloonBundle"] = message[14] ?? nil
      
      var reactions : [[String:Any]] = [[String:Any]]()
      for n in 0...attachments.count {
        reactions.append(contentsOf: getReactions(guid: "p:\(n)/"+(messageJson["guid"] as! String)))
      }
      if messageJson["balloonBundle"] != nil {
        reactions.append(contentsOf: getReactions(guid: "bp:"+(messageJson["guid"] as! String)))
      }
      messageJson["reactions"] = reactions
      
      messagesJson.append(messageJson)
    }
    
    let json = try! JSON(["action":"fetchMessages", "data": messagesJson]).rawData()
    webSocket.send(data: json)
  }
  
  private func serverHandleAttachments(request: HTTPRequest) -> HTTPResponse {
    var imageData = Data.init()
    var typeData = ""
    var filename = ""
    let transcode = request.params["transcode"] == "1"
    
    if let path = request.params["path"], let type = request.params["type"] {
      let safePath = path.replacingOccurrences(of: "../", with: "")
      if safePath.prefix(35) == "/var/mobile/Library/SMS/Attachments" || safePath.prefix(36) == "/var/mobile/Library/SMS/StickerCache" {
        typeData = type
        filename = safePath.components(separatedBy: "/").last!
        
        if (type == "image/heic" || filename.components(separatedBy: ".").last! == "heic") && transcode {
          let image = UIImage(contentsOfFile: safePath)
          imageData = image?.pngData() ?? Data.init(capacity: 0)
        } else if type == "video/quicktime" && transcode {
          let transcodedVideo = transcodeVideo(at: URL(fileURLWithPath: safePath))
          let transcodedData = transcodedVideo.0
          
          if (!transcodedData.isEmpty) {
            imageData = transcodedVideo.0
            filename = transcodedVideo.1
          } else {
            do {
              imageData = try Data.init(contentsOf: URL(fileURLWithPath: safePath))
            } catch { }
          }
        } else if filename.components(separatedBy: ".").last! == "caf" && transcode {
          let transcodedAudio = transcodeAudio(at: URL(fileURLWithPath: safePath))
          let transcodedData = transcodedAudio.0
          
          if (!transcodedData.isEmpty) {
            imageData = transcodedAudio.0
            filename = transcodedAudio.1
          } else {
            do {
              imageData = try Data.init(contentsOf: URL(fileURLWithPath: safePath))
            } catch { }
          }
        } else {
          do {
            imageData = try Data.init(contentsOf: URL(fileURLWithPath: safePath))
          } catch { }
        }
      }
    }
    
    if (request.headers.range != nil && !imageData.isEmpty) {
      let rangeHeader = request.headers.range!
      let rangeString = rangeHeader.split(separator: "=")[1]
      let range = rangeString.split(separator: "-")
      let startRange = String(range[0])
      let length = String(imageData.count - (Int(startRange) ?? 0))
      return HTTPResponse(.partialContent, headers: .init(dictionaryLiteral: (.contentType, typeData), (.contentDisposition, "attachment; filename=\(filename)"), (.acceptRanges, "0-\(imageData.count-1)"), (.contentRange, "bytes \(startRange)-\(imageData.count-1)/\(imageData.count)"), (.contentLength, length)), body: imageData.advanced(by: Int(startRange) ?? 0))
    }
    
    return HTTPResponse(.ok, headers: .init(dictionaryLiteral: (.contentType, typeData), (.contentDisposition, "attachment; filename=\(filename)"), (.acceptRanges, "0-\(imageData.count-1)")), body: imageData)
  }
  
  private func serverHandleContactImage(request: HTTPRequest) -> HTTPResponse {
    var imageData = Data.init()
    
    if let docidStr = request.params["docid"]  {
      if docidStr.prefix(4) == "chat" && !docidStr.contains("@") && docidStr.count >= 20 {
        let groupAvatar = try! db!.prepare("""
                            SELECT filename FROM attachment
                            WHERE ROWID in
                              (SELECT attachment_id FROM message_attachment_join WHERE message_id in
                                (SELECT ROWID FROM message WHERE group_action_type IS 1 AND cache_has_attachments IS 1 AND ROWID IN
                                  (SELECT message_id FROM chat_message_join WHERE chat_id IN
                                    (SELECT ROWID FROM chat WHERE chat_identifier IS ?)
                                  ) ORDER BY date DESC
                                )
                              )
                            LIMIT 1
        """)
        
        for avatarEntry in try! groupAvatar.run(docidStr) {
          do {
            imageData = try Data.init(contentsOf: URL(fileURLWithPath: (avatarEntry[0] as? String ?? "").replacingOccurrences(of: "~", with: "/var/mobile")))
          } catch { }
        }
      } else {
        let docid = Int(docidStr) ?? 0
        imageData = getContactImage(docid: docid)
      }
    }
    
    return HTTPResponse(.ok, headers: .init(dictionaryLiteral: (.contentType, "image/jpeg")), body: imageData)
  }
  
  private func serverHandleSearchContacts(request: HTTPRequest) -> HTTPResponse {
    var result : [[String:Any]] = [[String:Any]]()
    
    if let searchStr = request.params["text"]  {
      let contacts = try! contactsDB!.prepare("""
        SELECT COALESCE(c0First, '') || ' ' || COALESCE(c1Last, '') AS fullname, c16Phone, c17Email FROM ABPersonFullTextSearch_content
        WHERE (c16Phone LIKE ? OR fullname LIKE ? OR c17Email LIKE ?) AND (c16Phone NOT NULL OR c17Email NOT NULL)
      """)
      
      let searchWildcard = "%"+searchStr+"%"
      var numsUsed = [String]()
      
      for contact in try! contacts.run(searchWildcard, searchWildcard, searchWildcard) {
        let numsStr = contact[1] as? String ?? ""
        let nums = numsStr.components(separatedBy: " ")
        let emails = (contact[2] as? String ?? "").components(separatedBy: " ")
        let name = contact[0] as? String ?? ""
        
        for num in nums {
          if num.range(of: #"\+\d{11,16}"#, options: .regularExpression) != nil && !numsUsed.contains(num) {
            var contactJson : [String:Any] = [String:Any]()
            
            if let chat = try! db!.prepare("SELECT chat_identifier FROM \"chat\" INNER JOIN chat_message_join ON chat_id = ROWID WHERE chat_identifier LIKE \"\(num)\" LIMIT 1").next() {
              contactJson["personId"] = chat[0]!
            }
            
            contactJson["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            contactJson["phone"] = num
            
            result.append(contactJson)
            numsUsed.append(num)
          }
        }
        
        for email in emails {
          if (email != "" && !result.contains(where: { $0["phone"] as! String == email })) {
            var contactJson : [String:Any] = [String:Any]()
            
            if let chat = try! db!.prepare("SELECT chat_identifier FROM \"chat\" INNER JOIN chat_message_join ON chat_id = ROWID WHERE chat_identifier LIKE \"\(email)\" LIMIT 1").next() {
              contactJson["personId"] = chat[0]!
            }
            
            contactJson["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            contactJson["phone"] = email
            
            result.append(contactJson)
          }
        }
      }
    }
    
    let json = try! JSON(result).rawData()
    
    return HTTPResponse(.ok, headers: .init(dictionaryLiteral: (.contentType, "application/json")), body: json)
  }
}

// MARK: - ServerDelegate implementation

extension WebMessageServer: ServerDelegate {
  // Raised when the server gets disconnected.
  public func serverDidStop(_ server: Server, error: Error?) {
    print("[SERVER]", "Server stopped:", error?.localizedDescription ?? "graceful")
    exit(0)
  }
}

// MARK: - URLSessionDelegate implementation

extension WebMessageServer: URLSessionDelegate {
  public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                         completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    // Use our custom TLS policy to verify if the server should be trusted
    let credential = URLCredential(trust: challenge.protectionSpace.serverTrust!)
    completionHandler(.useCredential, credential)
  }
}

// MARK: Request helpers

extension WebMessageServer {
  /// Generates a server url, we'll assume the server has been started.
  private func serverURL(path: String = "") -> URL {
    var components = URLComponents()
    components.scheme = server.isSecure ? "https" : "http"
    components.host = getWiFiAddress()
    components.port = Int(server.port)
    components.path = path
    return components.url!
  }
  
  func getWiFiAddress() -> String? {
    var address : String?

    // Get list of all interfaces on the local machine:
    var ifaddr : UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0 else { return nil }
    guard let firstAddr = ifaddr else { return nil }

    // For each interface ...
    for ifptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
        let interface = ifptr.pointee

        // Check for IPv4 or IPv6 interface:
        let addrFamily = interface.ifa_addr.pointee.sa_family
        if addrFamily == UInt8(AF_INET) {

            // Check interface name:
            let name = String(cString: interface.ifa_name)
            if  name == "en0" {

                // Convert interface address to a human readable string:
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, socklen_t(0), NI_NUMERICHOST)
                address = String(cString: hostname)
            }
        }
    }
  
    freeifaddrs(ifaddr)

    return address
  }

  func getDisplayName(chat_id: String) -> [Any] {
    var display_name: String = ""
    var docid: Int = 0

    /// Support for group chats
    if chat_id.prefix(4) == "chat" && !chat_id.contains("@") && chat_id.count >= 20 {
      let nameRows = try! db!.prepare("SELECT display_name FROM chat WHERE chat_identifier IS \"\(chat_id)\" LIMIT 1")
      
      for row in nameRows {
        display_name = row[0] as? String ?? ""
      }
      
      if (display_name != "") {
        return [display_name, docid]
      } else {
        let recipients = getGroupContacts(chat_id: chat_id)
        return [recipients.joined(separator: ", "), docid]
      }
    }

    if chat_id.contains("@") {
      if let result = try! contactsDB!.prepare("SELECT c0First, c1Last, docid, ABPerson.PersonLink FROM ABPersonFullTextSearch_content LEFT JOIN ABPerson ON ABPerson.ROWID = docid WHERE c17Email LIKE \"%\(chat_id)%\" LIMIT 1").next() {
        if ((result[3] as? Int64 ?? -1) != -1) {
          let personLink = try! contactsDB!.prepare("SELECT PreferredImagePersonID, PreferredNamePersonID FROM ABPersonLink WHERE ROWID = \(result[3]!) LIMIT 1").next()!
          let personResult = try! contactsDB!.prepare("SELECT First, Last FROM ABPerson WHERE ROWID = \(personLink[1]!)").next()!
          
          display_name = "\(personResult[0] as? String ?? "") \(personResult[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
          docid = Int(exactly: personLink[1] as! Int64)!
        } else {
          display_name = "\(result[0] as? String ?? "") \(result[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
          docid = Int(exactly: result[2] as! Int64)!
        }
      }
    } else if chat_id.contains("+") {
      if let result = try! contactsDB!.prepare("SELECT c0First, c1Last, docid, ABPerson.PersonLink FROM ABPersonFullTextSearch_content LEFT JOIN ABPerson ON ABPerson.ROWID = docid WHERE c16Phone LIKE \"%\(chat_id)%\" LIMIT 1").next() {
        if ((result[3] as? Int64 ?? -1) != -1) {
          let personLink = try! contactsDB!.prepare("SELECT PreferredImagePersonID, PreferredNamePersonID FROM ABPersonLink WHERE ROWID = \(result[3]!) LIMIT 1").next()!
          let personResult = try! contactsDB!.prepare("SELECT First, Last FROM ABPerson WHERE ROWID = \(personLink[1]!)").next()!
          
          display_name = "\(personResult[0] as? String ?? "") \(personResult[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
          docid = Int(exactly: personLink[1] as! Int64)!
        } else {
          display_name = "\(result[0] as? String ?? "") \(result[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
          docid = Int(exactly: result[2] as! Int64)!
        }
      }
    } else {
      if let result = try! contactsDB!.prepare("SELECT c0First, c1Last, docid, ABPerson.PersonLink FROM ABPersonFullTextSearch_content LEFT JOIN ABPerson ON ABPerson.ROWID = docid WHERE c16Phone LIKE \"%\(chat_id)%\" and c16Phone NOT LIKE \"%+%\" LIMIT 1").next() {
        if ((result[3] as? Int64 ?? -1) != -1) {
          let personLink = try! contactsDB!.prepare("SELECT PreferredImagePersonID, PreferredNamePersonID FROM ABPersonLink WHERE ROWID = \(result[3]!) LIMIT 1").next()!
          let personResult = try! contactsDB!.prepare("SELECT First, Last FROM ABPerson WHERE ROWID = \(personLink[1]!)").next()!
          
          display_name = "\(personResult[0] as? String ?? "") \(personResult[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
          docid = Int(exactly: personLink[1] as! Int64)!
        } else {
          display_name = "\(result[0] as? String ?? "") \(result[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
          docid = Int(exactly: result[2] as! Int64)!
        }
      }
    }
    

    if display_name == "" {
      if let result = try! db!.prepare("SELECT uncanonicalized_id FROM handle WHERE id IS \"\(chat_id)\"").next() {
        display_name = result[0] as? String ?? chat_id
      }
    }
    
    return [display_name, docid]
  }
  
  func getGroupContacts(chat_id: String) -> [String] {
    let contacts = try! db!.prepare("SELECT id FROM handle WHERE ROWID IN (SELECT handle_id FROM chat_handle_join WHERE chat_id IN (SELECT ROWID FROM chat WHERE chat_identifier = ?))")

    var result = [String]()

    for contact in try! contacts.run(chat_id) {
      let chat_id = contact[0] as? String ?? ""
      if chat_id == "" || (chat_id.prefix(4) == "chat" && !chat_id.contains("@") && chat_id.count >= 20) {
        continue
      }
      
      let contactData = getDisplayName(chat_id: chat_id)
      let recipientName = contactData[0] as! String
      if !result.contains(recipientName) {
        result.append(recipientName)
      }
    }

    return result
  }
  
  func getContactImage(docid: Int) -> Data {
    var pngdata = Data.init()
//    do {
//      pngdata = try Data.init(contentsOf: URL(fileURLWithPath: "/Library/Application Support/WebMessage/defaultAvatar.jpg"))
//    } catch { }
    
    if docid > 0, let result = try! imageDB!.prepare("SELECT data FROM ABThumbnailImage WHERE record_id = \(docid) LIMIT 1").next() {
      if let blobData = result[0] as? SQLite.Blob {
        pngdata = Data.fromDatatypeValue(blobData)
      }
    }
    
    return pngdata
  }
  
  func getAttachments(mid: Int64) -> [[String]] {
    let filesQuery = try! db!.prepare("SELECT filename, mime_type FROM attachment WHERE ROWID IN (SELECT attachment_id FROM message_attachment_join WHERE message_id IS \(mid))")
    var files = [[String]]()

    for file in filesQuery {
      let filepath = (file[0] as? String ?? "").replacingOccurrences(of: "~", with: "/var/mobile")
      let type = file[1] as? String ?? ""
      files.append([filepath, type])
    }

    return files
  }
  
  func getReactions(guid: String) -> [[String:Any]] {
    var reactionsJson : [[String:Any]] = [[String:Any]]()
    var chat_id = ""
    var isMe = false
    
    let reactions = try! db!.prepare("""
                    SELECT message_id, service_name, text, max(date), is_from_me, chat.room_name, chat_identifier,
                           date_delivered, date_read, message.guid, associated_message_type, associated_message_guid FROM "message"
                    INNER JOIN "chat_message_join" AS CMJ ON ("message_id" = "message"."ROWID")
                    LEFT JOIN "chat" ON ("chat"."ROWID" = CMJ."chat_id")
                    LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
                    WHERE associated_message_guid = ? AND associated_message_type NOT NULL
                    GROUP BY is_from_me, handle.id
                    ORDER BY date DESC
    """)
    
    for reaction in try! reactions.run(guid) {
      var reactionJson : [String:Any] = [String:Any]()
      
      reactionJson["id"] = reaction[0]!
      reactionJson["type"] = reaction[1]!
      reactionJson["text"] = reaction[2] ?? ""
      reactionJson["date"] = (reaction[3] as! Int64 + 978307200000000000) / 1000000
      reactionJson["sender"] = reaction[4]!
      reactionJson["group"] = reaction[5] ?? nil
      reactionJson["chatId"] = reaction[6]!
      reactionJson["dateDelivered"] = reaction[7] as! Int64 == 0 ? 0 : ((reaction[7] as! Int64 + 978307200000000000) / 1000000)
      reactionJson["dateRead"] = reaction[8] as! Int64 == 0 ? 0 : ((reaction[8] as! Int64 + 978307200000000000) / 1000000)
      reactionJson["guid"] = reaction[9] ?? ""
      reactionJson["personId"] = reactionJson["chatId"]
      reactionJson["reactionType"] = reaction[10]!
      
      if (reaction[11] as! String).prefix(2) == "bp" {
        let associated_message_guid_split = (reaction[11] as! String).split(separator: ":")
        let forGUID = associated_message_guid_split[1]
        reactionJson["forGUID"] = forGUID
        reactionJson["forPart"] = "b"
      } else {
        let associated_message_guid_split = (reaction[11] as! String).split(separator: "/")
        let forGUID = associated_message_guid_split[1]
        let forPart = associated_message_guid_split[0].split(separator: ":")[1]
        reactionJson["forGUID"] = forGUID
        reactionJson["forPart"] = forPart
      }
      
      chat_id = reactionJson["chatId"] as! String
      isMe = reactionJson["sender"] as! Int64 == 1
      
      reactionsJson.append(reactionJson)
    }
    
    if chat_id != "" && isMe {
      sender.setAsRead(chat_id)
    }
    
    return reactionsJson
  }
  
  func getTextByGUID(guid: String, webSocket: WebSocket? = nil) {
    DispatchQueue.main.async {
      var messagesJson : [[String:Any]] = [[String:Any]]()
      var chat_id = ""
      var isMe = false
      
      var total = 0
      let begin = 10000
      let max = begin * 50
      
      let messages = try! self.db!.prepare("""
                   SELECT message_id, service_name, text, date, is_from_me, cache_has_attachments, chat.room_name, chat_identifier,
                          handle.id, date_delivered, date_read, message.guid, subject, payload_data, balloon_bundle_id, associated_message_guid FROM "message"
                   INNER JOIN "chat_message_join" AS CMJ ON ("message_id" = "message"."ROWID")
                   LEFT JOIN "chat" ON ("chat"."ROWID" = CMJ."chat_id")
                   LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
                   WHERE message.guid = ?
      """)
      
      while (messagesJson.count == 0 && total <= max) {
        for message in try! messages.run(guid) {
          if message[15] != nil {
            //It's a reaction!
            let associated_guid = message[15] as! String
            let chat_id = message[7] as! String
            
            var seperatedGuid = associated_guid.split(separator: "/")
            var forGuid = ""
            
            if seperatedGuid.count == 1 {
              seperatedGuid = associated_guid.split(separator: ":")
              if seperatedGuid.count == 1 {
                seperatedGuid.append(seperatedGuid[0])
              }
            }
            
            forGuid = String(seperatedGuid[1])
            
            for parentMessage in try! self.db!.prepare("SELECT ROWID, balloon_bundle_id FROM message WHERE guid = ? LIMIT 1").run(forGuid) {
              var reactions : [[String:Any]] = [[String:Any]]()
              
              for n in 0...self.getAttachments(mid: parentMessage[0] as! Int64).count {
                reactions.append(contentsOf: self.getReactions(guid: "p:\(n)/\(forGuid)"))
              }
              
              if parentMessage[1] != nil {
                reactions.append(contentsOf: self.getReactions(guid: "bp:"+forGuid))
              }

              let chatsJson = self.getChat(chat_id: chat_id)
              let json = try! JSON(["action":"newReaction", "data": ["reactions": reactions, "chat": chatsJson]]).rawData()
              
              for client in self.clients {
                client.send(data: json)
              }
            }
            
            return
          }
          
          var messageJson : [String:Any] = [String:Any]()
          var attachments: [[String]] = []
          
          let contactData = self.getDisplayName(chat_id: message[7] as? String ?? "")
          messageJson["name"] = contactData[0]
          messageJson["docid"] = contactData[1]
          
          let authorData = self.getDisplayName(chat_id: message[8] as? String ?? "")
          
          if (message[5] as! Int64 == 1) {
            attachments = self.getAttachments(mid: message[0] as! Int64)
          }
          
          messageJson["id"] = message[0]!
          messageJson["type"] = message[1]!
          messageJson["text"] = message[2] ?? ""
          messageJson["date"] = (message[3] as! Int64 + 978307200000000000) / 1000000
          messageJson["sender"] = message[4]!
          messageJson["attachments"] = attachments
          messageJson["group"] = message[6] ?? nil
          messageJson["chatId"] = message[7]!
          messageJson["author"] = authorData[0]
          messageJson["authorDocid"] = authorData[1]
          messageJson["dateDelivered"] = message[9] as! Int64 == 0 ? 0 : ((message[9] as! Int64 + 978307200000000000) / 1000000)
          messageJson["dateRead"] = message[10] as! Int64 == 0 ? 0 : ((message[10] as! Int64 + 978307200000000000) / 1000000)
          messageJson["guid"] = message[11] ?? ""
          messageJson["personId"] = messageJson["chatId"]
          messageJson["subject"] = message[12] ?? nil
          if let payloadData = message[13] as? SQLite.Blob {
            messageJson["payload"] = Data.fromDatatypeValue(payloadData).base64EncodedString()
          }
          messageJson["balloonBundle"] = message[14] ?? nil
          
          chat_id = messageJson["chatId"] as! String
          isMe = messageJson["sender"] as! Int64 == 1
          
          var reactions : [[String:Any]] = [[String:Any]]()
          for n in 0...attachments.count {
            reactions.append(contentsOf: self.getReactions(guid: "p:\(n)/"+(messageJson["guid"] as! String)))
          }
          if messageJson["balloonBundle"] != nil {
            reactions.append(contentsOf: self.getReactions(guid: "bp:"+(messageJson["guid"] as! String)))
          }
          messageJson["reactions"] = reactions
          
          messagesJson.append(messageJson)
        }
        
        usleep(useconds_t(begin))
        total += begin
      }
      
      if chat_id != "" && isMe {
        self.sender.setAsRead(chat_id)
      }
      
      if (messagesJson.count == 0) {
        return
      }
      
      let chatsJson = self.getChat(chat_id: chat_id)
      let json = try! JSON(["action":"newMessage", "data": ["message": messagesJson, "chat": chatsJson]]).rawData()
      
      if let webSocket = webSocket {
        webSocket.send(data: json)
      } else {
        for client in self.clients {
          client.send(data: json)
        }
      }
    }
  }
  
  func getChat(chat_id: String) -> [[String:Any]] {
    let chats = try! db!.prepare("""
        SELECT CMJ.chat_id, chat_identifier, text, cache_has_attachments, max(message."date"),
               last_read_message_timestamp, is_from_me, item_type, is_read,
               associated_message_guid, handle.id FROM "chat"
        INNER JOIN "chat_message_join" AS CMJ ON (CMJ."chat_id" = "chat"."ROWID")
        INNER JOIN "message" ON ("message"."ROWID" = "message_id")
        INNER JOIN "chat_handle_join" AS CHJ ON (CHJ."chat_id" = chat.ROWID)
        LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
        WHERE chat_identifier = "\(chat_id)" AND text NOT NULL
        GROUP BY chat_identifier
        ORDER BY "message"."date" DESC
        LIMIT 1
      """)
    
    var chatsJson : [[String:Any]] = [[String:Any]]()
    for chat in chats {
      var chatJson : [String:Any] = [String:Any]()
      
      let contactData = getDisplayName(chat_id: chat[1] as? String ?? "")
      
      chatJson["id"] = chat[0]!
      chatJson["author"] = contactData[0]
      chatJson["docid"] = contactData[1]
      
      if chat[9] != nil {
        let authorName = chat[10] != nil ? getDisplayName(chat_id: chat[10] as? String ?? "")[0] as! String : ""
        let textContent = chat[2] as? String ?? ""
        let authorPreview = (chat[6] as! Int64 == 1) ? "You" : String(authorName.split(separator: " ")[0])
        chatJson["text"] = authorPreview + " " + String(textContent.prefix(1)).lowercased() + textContent.dropFirst()
      } else {
        chatJson["text"] = chat[2] ?? ""
      }
      
      chatJson["attachment"] = chat[3]!
      chatJson["date"] = (chat[4] as! Int64 + 978307200000000000) / 1000000
      chatJson["read"] = chat[5] as! Int64 > chat[4] as! Int64 || chat[6] as! Int64 == 1 || chat[7] as! Int64 != 0 || chat[8] as! Int64 == 1
      chatJson["address"] = chat[1]!
      chatJson["personId"] = chatJson["address"]
      
      chatsJson.append(chatJson)
    }
    
    return chatsJson
  }

  func transcodeVideo(at videoURL: URL) -> (Data, String)  {
    let avAsset = AVURLAsset(url: videoURL, options: nil)
    var returnData = Data.init()

    let filePath = videoURL.deletingLastPathComponent().appendingPathComponent(videoURL.lastPathComponent.replacingOccurrences(of: ".mov", with: ".mp4").replacingOccurrences(of: ".MOV", with: ".mp4"))
    let fileName = filePath.lastPathComponent
        
    //Create Export session
    guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetHighestQuality) else {
      return (returnData, "")
    }
        
    // Check if the file already exists
    if FileManager.default.fileExists(atPath: filePath.path) {
      do {
        returnData = try Data.init(contentsOf: filePath)
      } catch { }
      
      return (returnData, fileName)
    }

    exportSession.outputURL = filePath
    exportSession.outputFileType = AVFileType.mp4
    exportSession.shouldOptimizeForNetworkUse = true
    let start = CMTimeMakeWithSeconds(0.0, preferredTimescale: 0)
    let range = CMTimeRangeMake(start: start, duration: avAsset.duration)
    exportSession.timeRange = range
    
    let group = DispatchGroup()
    group.enter()
        
    exportSession.exportAsynchronously(completionHandler: {() -> Void in
      switch exportSession.status {
        case .failed:
          group.leave()
          print("[SERVER] Converting file failed:", exportSession.error ?? "No error")
        case .cancelled:
          group.leave()
          print("[SERVER] Conversion canceled")
        case .completed:
          do {
            returnData = try Data.init(contentsOf: exportSession.outputURL!)
          } catch { }
          group.leave()
        default:
          group.leave()
          break
      }
    })
    
    group.wait()
    return (returnData, fileName)
  }

  func transcodeAudio(at audioURL: URL) -> (Data, String)  {
    let avAsset = AVURLAsset(url: audioURL, options: nil)
    var returnData = Data.init()

    let filePath = audioURL.deletingLastPathComponent().appendingPathComponent(audioURL.lastPathComponent.replacingOccurrences(of: ".caf", with: ".m4a").replacingOccurrences(of: ".CAF", with: ".m4a"))
    let fileName = filePath.lastPathComponent
        
    //Create Export session
    guard let exportSession = AVAssetExportSession(asset: avAsset, presetName: AVAssetExportPresetAppleM4A) else {
      return (returnData, "")
    }
        
    // Check if the file already exists
    if FileManager.default.fileExists(atPath: filePath.path) {
      do {
        returnData = try Data.init(contentsOf: filePath)
      } catch { }
      
      return (returnData, fileName)
    }

    exportSession.outputURL = filePath
    exportSession.outputFileType = AVFileType.m4a
    exportSession.shouldOptimizeForNetworkUse = true
    let start = CMTimeMakeWithSeconds(0.0, preferredTimescale: 0)
    let range = CMTimeRangeMake(start: start, duration: avAsset.duration)
    exportSession.timeRange = range
    
    let group = DispatchGroup()
    group.enter()
        
    exportSession.exportAsynchronously(completionHandler: {() -> Void in
      switch exportSession.status {
        case .failed:
          group.leave()
          print("[SERVER] Converting file failed:", exportSession.error ?? "No error")
        case .cancelled:
          group.leave()
          print("[SERVER] Conversion canceled")
        case .completed:
          do {
            returnData = try Data.init(contentsOf: exportSession.outputURL!)
          } catch { }
          group.leave()
        default:
          group.leave()
          break
      }
    })
    
    group.wait()
    return (returnData, fileName)
  }
}
