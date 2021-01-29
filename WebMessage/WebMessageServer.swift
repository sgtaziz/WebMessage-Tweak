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
    
    //db!.trace { print($0) }
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
      if let value = value {
        self.getTextByGUID(guid: value)
      }
    }
    
    watcher.stopWebserver = { arg in
      self.stop()
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
    response!.headers.accessControlAllowMethods = "GET, POST, OPTIONS"
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
  private func serverHandleSendText(request: HTTPRequest) -> HTTPResponse {
    let data = try? JSON(data: request.body)
    if let data = data {
      let text: String = data["text"].string ?? ""
      let address: String = data["address"].string ?? ""
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
        sender.sendText(text, withSubject: "", toAddress: address, withAttachments: attachments)
        return HTTPResponse(.ok)
      }
    }
    
    return HTTPResponse(.badRequest)
  }
  
  private func serverHandleChats(webSocket: WebSocket, data: JSON) {
    let chats = try! db!.prepare("""
        SELECT CMJ.chat_id, message_id, chat_identifier, text, cache_has_attachments, max(message."date"),
               last_read_message_timestamp, is_from_me, item_type, is_read FROM "chat"
        INNER JOIN "chat_message_join" AS CMJ ON (CMJ."chat_id" = "chat"."ROWID")
        INNER JOIN "message" ON ("message"."ROWID" = "message_id")
        INNER JOIN "chat_handle_join" AS CHJ ON (CHJ."chat_id" = chat.ROWID)
        INNER JOIN "handle" ON (handle."ROWID" = CHJ."handle_id")
        WHERE text NOT NULL
        GROUP BY chat_identifier
        ORDER BY "message"."date" DESC
        LIMIT ? OFFSET ?
      """)
    
    var chatsJson : [[String:Any]] = [[String:Any]]()
    for chat in try! chats.run(data["limit"].string ?? "25", data["offset"].string ?? "0") {
      var chatJson : [String:Any] = [String:Any]()
      
      let contactData = getDisplayName(chat_id: chat[2] as! String)
      
      chatJson["id"] = chat[0]!
      chatJson["author"] = contactData[0]
      chatJson["docid"] = contactData[1]
      chatJson["text"] = chat[3]!
      chatJson["attachment"] = chat[4]!
      chatJson["date"] = (chat[5] as! Int64 / 1000000000) + 978307200
      chatJson["read"] = chat[6] as! Int64 > chat[5] as! Int64 || chat[7] as! Int64 == 1 || chat[8] as! Int64 != 0 || chat[9] as! Int64 == 1
      chatJson["address"] = chat[2]!
      
      chatsJson.append(chatJson)
    }
    
    let json = try! JSON(["action":"fetchChats", "data":chatsJson]).rawData()
    webSocket.send(data: json)
  }
  
  private func serverHandleMessages(webSocket: WebSocket, data: JSON) {
    let id = data["id"].string ?? "0"
    let messages = try! db!.prepare("""
        SELECT message_id, service_name, uncanonicalized_id, text, date, is_from_me, cache_has_attachments,
               message.handle_id, cache_roomnames, handle.id, display_name, chat_identifier FROM "message"
        INNER JOIN "chat_message_join" AS CMJ ON ("message_id" = "message"."ROWID")
        LEFT JOIN "chat" ON ("chat"."ROWID" = CMJ."chat_id")
        LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
        WHERE chat.chat_identifier LIKE ?
        AND associated_message_guid IS NULL
        ORDER BY "message"."date" DESC
        LIMIT ? OFFSET ?
      """)
    
    var messagesJson : [[String:Any]] = [[String:Any]]()
    var chat_id = ""
    
    for message in try! messages.run(id, data["limit"].string ?? "25", data["offset"].string ?? "0") {
      var messageJson : [String:Any] = [String:Any]()
      var attachments: [[String]] = []
      
      let contactData = getDisplayName(chat_id: message[11] as! String)
      
      if (message[6] as! Int64 == 1) {
        attachments = getAttachments(mid: message[0] as! Int64)
      }
      
      messageJson["id"] = message[0]!
      messageJson["type"] = message[1]!
      messageJson["author"] = getDisplayName(chat_id: message[9] as? String ?? message[11] as! String)[0]
      messageJson["name"] = contactData[0]
      messageJson["docid"] = contactData[1]
      messageJson["address"] = message[11]!
      messageJson["text"] = message[3] ?? ""
      messageJson["date"] = (message[4] as! Int64 / 1000000000) + 978307200
      messageJson["sender"] = message[5]!
      messageJson["attachments"] = attachments
      messageJson["group"] = message[8] ?? nil
      messageJson["chatId"] = id
      chat_id = message[11] as! String
      
      messagesJson.append(messageJson)
    }
    
    let json = try! JSON(["action":"fetchMessages", "data":messagesJson]).rawData()
    webSocket.send(data: json)
    
    if chat_id != "" {
      sender.setAsRead(chat_id)
    }
  }
  
  private func serverHandleAttachments(request: HTTPRequest) -> HTTPResponse {
    var imageData = Data.init()
    var typeData = ""
    var filename = ""
    
    if let path = request.params["path"], let type = request.params["type"] {
      let safePath = path.replacingOccurrences(of: "../", with: "")
      if safePath.prefix(35) == "/var/mobile/Library/SMS/Attachments" {
        typeData = type
        filename = safePath.components(separatedBy: "/").last!
        
        if type == "image/heic" {
          let image = UIImage(contentsOfFile: safePath)
          imageData = image?.jpegData(compressionQuality: 0) ?? Data.init(capacity: 0)
        } else {
          do {
            imageData = try Data.init(contentsOf: URL(fileURLWithPath: safePath))
          } catch { }
        }
      }
    }
    
    return HTTPResponse(.ok, headers: .init(dictionaryLiteral: (.contentType, typeData), (.contentDisposition, "attachment; filename=\(filename)")), body: imageData)
  }
  
  private func serverHandleContactImage(request: HTTPRequest) -> HTTPResponse {
    var imageData = Data.init()
    
    if let docidStr = request.params["docid"]  {
      let docid = Int(docidStr) ?? 0
      imageData = getContactImage(docid: docid)
    }
    
    return HTTPResponse(.ok, headers: .init(dictionaryLiteral: (.contentType, "image/jpeg")), body: imageData)
  }
  
  private func serverHandleSearchContacts(request: HTTPRequest) -> HTTPResponse {
    var result : [[String:Any]] = [[String:Any]]()
    
    if let searchStr = request.params["text"]  {
      let contacts = try! contactsDB!.prepare("""
        SELECT COALESCE(c0First, '') || ' ' || COALESCE(c1Last, '') AS fullname, c16Phone, c17Email FROM ABPersonFullTextSearch_content
        WHERE (c16Phone LIKE ? OR fullname LIKE ?) AND c16Phone NOT NULL
      """) /// Can add "c17Email LIKE ?" OR" to send to emails later
      
      let searchWildcard = "%"+searchStr+"%"
      var numsUsed = [String]()
      
      for contact in try! contacts.run(searchWildcard, searchWildcard) {
        var contactJson : [String:Any] = [String:Any]()
        
        let numsStr = contact[1] as! String
        let nums = numsStr.components(separatedBy: " ")
        
        for num in nums {
          if num.range(of: #"\+\d{11,16}"#, options: .regularExpression) != nil && !numsUsed.contains(num), let name = contact[0] as? String {
            contactJson["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
            contactJson["phone"] = num
            contactJson["email"] = contact[2] ?? ""
            
            if let chat = try! db!.prepare("SELECT chat_identifier FROM \"chat\" WHERE chat.chat_identifier LIKE \"\(num)\" LIMIT 1").next() {
              contactJson["chatId"] = chat[0]!
            }
            
            numsUsed.append(num)
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
      if let result = try! contactsDB!.prepare("SELECT c0First, c1Last, docid FROM ABPersonFullTextSearch_content WHERE c17Email LIKE \"%\(chat_id)%\"").next() {
        display_name = "\(result[0] as? String ?? "") \(result[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        docid = Int(exactly: result[2] as! Int64)!
      }
    } else if chat_id.contains("+") {
      if let result = try! contactsDB!.prepare("SELECT c0First, c1Last, docid FROM ABPersonFullTextSearch_content WHERE c16Phone LIKE \"%\(chat_id)%\"").next() {
        display_name = "\(result[0] as? String ?? "") \(result[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        docid = Int(exactly: result[2] as! Int64)!
      }
    } else {
      if let result = try! contactsDB!.prepare("SELECT c0First, c1Last, docid FROM ABPersonFullTextSearch_content WHERE c16Phone LIKE \"%\(chat_id)%\" and c16Phone NOT LIKE \"%+%\"").next() {
        display_name = "\(result[0] as? String ?? "") \(result[1] as? String ?? "")".trimmingCharacters(in: .whitespacesAndNewlines)
        docid = Int(exactly: result[2] as! Int64)!
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
    let contacts = try! db!.prepare("SELECT id FROM handle WHERE ROWID IN (SELECT handle_id FROM chat_handle_join WHERE chat_id IN (SELECT ROWID FROM chat WHERE chat_identifier IS \"\(chat_id)\"))")

    var result = [String]()

    for contact in contacts {
      let name = getDisplayName(chat_id: contact[0] as? String ?? "")[0]
      result.append(name as! String)
    }

    return result
  }
  
  func getContactImage(docid: Int) -> Data {
    var pngdata = Data.init()
    do {
      pngdata = try Data.init(contentsOf: URL(fileURLWithPath: "/Library/Application Support/WebMessage/defaultAvatar.jpg"))
    } catch { }
    
    if docid > 0, let result = try! imageDB!.prepare("SELECT data FROM ABThumbnailImage WHERE record_id=\"\(docid)\"").next() {
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
  
  func getTextByGUID(guid: String) {
    var messages = try! db!.prepare("""
                      SELECT message_id, service_name, uncanonicalized_id, text, date, is_from_me, cache_has_attachments,
                             message.handle_id, cache_roomnames, handle.id, display_name, chat_identifier, CMJ."chat_id" FROM "message"
                      INNER JOIN "chat_message_join" AS CMJ ON ("message_id" = "message"."ROWID")
                      LEFT JOIN "chat" ON ("chat"."ROWID" = CMJ."chat_id")
                      LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
                      WHERE message.guid = \"\(guid)\" AND text NOT NULL AND associated_message_guid IS NULL
    """)
    
    var total = 0
    let begin = 50000
    let max = begin * 5

    while messages.columnCount > 0 && total <= max {
      usleep(useconds_t(begin)) // SMServer does this since a message is received before its written to the database
      total += begin

       messages = try! db!.prepare("""
                     SELECT message_id, service_name, uncanonicalized_id, text, date, is_from_me, cache_has_attachments,
                            message.handle_id, cache_roomnames, handle.id, display_name, chat_identifier FROM "message"
                     INNER JOIN "chat_message_join" AS CMJ ON ("message_id" = "message"."ROWID")
                     LEFT JOIN "chat" ON ("chat"."ROWID" = CMJ."chat_id")
                     LEFT JOIN "handle" ON (handle."ROWID" = message."handle_id")
                     WHERE message.guid = \"\(guid)\" AND text NOT NULL AND associated_message_guid IS NULL
       """)
    }
    
    var messagesJson : [[String:Any]] = [[String:Any]]()
    var chat_id = ""
    var isMe = false
    
    for message in messages {
      var messageJson : [String:Any] = [String:Any]()
      var attachments: [[String]] = []
      
      let contactData = getDisplayName(chat_id: message[11] as! String)
      
      if (message[6] as! Int64 == 1) {
        attachments = getAttachments(mid: message[0] as! Int64)
      }
      
      messageJson["id"] = message[0]!
      messageJson["type"] = message[1]!
      messageJson["author"] = getDisplayName(chat_id: message[9] as? String ?? message[11] as! String)[0]
      messageJson["name"] = contactData[0]
      messageJson["docid"] = contactData[1]
      messageJson["address"] = message[11]!
      messageJson["text"] = message[3] ?? ""
      messageJson["date"] = (message[4] as! Int64 / 1000000000) + 978307200
      messageJson["sender"] = message[5]!
      messageJson["attachments"] = attachments
      messageJson["group"] = message[8] ?? nil
      messageJson["chatId"] = message[11]!
      chat_id = message[11] as! String
      isMe = message[5] as! Int64 == 1
      
      messagesJson.append(messageJson)
    }
    
    let chats = try! db!.prepare("""
        SELECT CMJ.chat_id, message_id, chat_identifier, text, cache_has_attachments, max(message."date"),
               last_read_message_timestamp, is_from_me, item_type, is_read FROM "chat"
        INNER JOIN "chat_message_join" AS CMJ ON (CMJ."chat_id" = "chat"."ROWID")
        INNER JOIN "message" ON ("message"."ROWID" = "message_id")
        INNER JOIN "chat_handle_join" AS CHJ ON (CHJ."chat_id" = chat.ROWID)
        INNER JOIN "handle" ON (handle."ROWID" = CHJ."handle_id")
        WHERE chat_identifier LIKE "\(chat_id)" AND text NOT NULL
        GROUP BY chat_identifier
        ORDER BY "message"."date" DESC
        LIMIT 1
      """)
    
    var chatsJson : [[String:Any]] = [[String:Any]]()
    for chat in chats {
      var chatJson : [String:Any] = [String:Any]()
      
      let contactData = getDisplayName(chat_id: chat[2] as! String)
      
      chatJson["id"] = chat[0]!
      chatJson["author"] = contactData[0]
      chatJson["docid"] = contactData[1]
      chatJson["text"] = chat[3]!
      chatJson["attachment"] = chat[4]!
      chatJson["date"] = (chat[5] as! Int64 / 1000000000) + 978307200
      chatJson["read"] = chat[6] as! Int64 > chat[5] as! Int64 || chat[7] as! Int64 == 1 || chat[8] as! Int64 != 0 || chat[9] as! Int64 == 1
      chatJson["address"] = chat[2]!
      
      chatsJson.append(chatJson)
    }
    
    let json = try! JSON(["action":"newMessage", "data": ["message": messagesJson, "chat": chatsJson]]).rawData()
    
    for client in clients {
      client.send(data: json)
    }
    
    if chat_id != "" && isMe {
      sender.setAsRead(chat_id)
    }
  }
}
