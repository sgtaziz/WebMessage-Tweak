import Foundation
import Telegraph

let server = WebMessageServer()
server.start()

//Memory limits imposed by jetsam are unreasonably low (6MB)
//Therefore, loading images causes the process to crash.
var token: Int32 = 0
memorystatus_control(UInt32(MEMORYSTATUS_CMD_SET_JETSAM_HIGH_WATER_MARK), getpid(), 500, &token, 0)

dispatchMain()
