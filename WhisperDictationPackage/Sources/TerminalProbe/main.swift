import Darwin
import Foundation

let resultPath = CommandLine.arguments
    .first(where: { $0.hasPrefix("--result=") })?
    .dropFirst("--result=".count)
    .description
    ?? "/private/tmp/whisperdictation-terminal-probe.bin"

FileManager.default.createFile(atPath: resultPath, contents: Data())
let resultHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: resultPath))
defer {
    try? resultHandle.close()
}

var original = termios()
guard tcgetattr(STDIN_FILENO, &original) == 0 else {
    exit(2)
}

var raw = original
cfmakeraw(&raw)
guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else {
    exit(3)
}
defer {
    var restored = original
    tcsetattr(STDIN_FILENO, TCSANOW, &restored)
}

FileHandle.standardOutput.write(Data("PROBE> ".utf8))

var bytes = [UInt8](repeating: 0, count: 4_096)
while true {
    let count = read(STDIN_FILENO, &bytes, bytes.count)
    if count > 0 {
        resultHandle.seekToEndOfFile()
        resultHandle.write(Data(bytes.prefix(count)))
        try? resultHandle.synchronize()
    } else if count == 0 {
        break
    } else if errno != EINTR {
        exit(4)
    }
}
