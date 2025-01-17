import Foundation
import Zip

public enum Logger {
    
    private static let queue = DispatchQueue(label: "one.mixin.services.queue.log")
    private static let systemLog = "system"
    private static let errorLog = "error"

    public static func write(error: Error, extra: String = "") {
        queue.async {
            makeLogDirectoryIfNeeded()
            writeLog(filename: errorLog, log: String(describing: error), newSection: true)
        }
    }
    
    public static func write(log: String, newSection: Bool = false) {
        queue.async {
            makeLogDirectoryIfNeeded()

            if log.hasPrefix("No sender key for:"), let conversationId = log.suffix(char: ":")?.substring(endChar: ":").trim() {
                write(conversationId: conversationId, log: log, newSection: newSection)
            } else {
                writeLog(filename: systemLog, log: log, newSection: newSection)
            }
        }
    }
    
    public static func write(conversationId: String, log: String, newSection: Bool = false) {
        guard LoginManager.shared.isLoggedIn else {
            return
        }
        guard !conversationId.isEmpty else {
            write(log: log, newSection: newSection)
            return
        }
        queue.async {
            writeLog(filename: conversationId, log: log, newSection: newSection)
        }
    }

    private static func writeLog(filename: String, log: String, newSection: Bool = false) {
        makeLogDirectoryIfNeeded()
        var log = "\(isAppExtension ? "[AppExtension]" : "")" + log + "...\(DateFormatter.filename.string(from: Date()))\n"
        if newSection {
            log += "------------------------------\n"
        }
        let url = AppGroupContainer.logUrl.appendingPathComponent("\(filename).txt")
        let path = url.path
        do {
            if FileManager.default.fileExists(atPath: path) && FileManager.default.fileSize(path) > 1024 * 1024 * 2 {
                guard let fileHandle = FileHandle(forUpdatingAtPath: path) else {
                    return
                }
                fileHandle.seek(toFileOffset: 1024 * 1024 * 1 + 1024 * 896)
                let lastString = String(data: fileHandle.readDataToEndOfFile(), encoding: .utf8)
                fileHandle.closeFile()
                try FileManager.default.removeItem(at: url)
                try lastString?.write(toFile: path, atomically: true, encoding: .utf8)
            }

            if FileManager.default.fileExists(atPath: path) {
                guard let data = log.data(using: .utf8) else {
                    return
                }
                guard let fileHandle = FileHandle(forUpdatingAtPath: path) else {
                    return
                }
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            } else {
                try log.write(toFile: path, atomically: true, encoding: .utf8)
            }
        } catch {
            #if DEBUG
            print("======FileManagerExtension...writeLog...error:\(error)")
            #endif
            reporter.report(error: error)
        }
    }
    
    public static func export(conversationId: String) -> URL? {
        makeLogDirectoryIfNeeded()
        let conversationFile = AppGroupContainer.logUrl.appendingPathComponent("\(conversationId).txt")
        let systemFile = AppGroupContainer.logUrl.appendingPathComponent("\(systemLog).txt")
        let errorFile = AppGroupContainer.logUrl.appendingPathComponent("\(errorLog).txt")
        let filename = "\(myIdentityNumber)_\(DateFormatter.filename.string(from: Date()))"

        var logFiles = [conversationFile, systemFile]
        if FileManager.default.fileSize(errorFile.path) > 0 {
            logFiles += [errorFile]
        }
        do {
            return try Zip.quickZipFiles(logFiles, fileName: filename)
        } catch {
            #if DEBUG
            print("======FileManagerExtension...exportLog...error:\(error)")
            #endif
            reporter.report(error: error)
        }
        return nil
    }
    
    private static func makeLogDirectoryIfNeeded() {
        guard !FileManager.default.fileExists(atPath: AppGroupContainer.logUrl.path) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: AppGroupContainer.logUrl, withIntermediateDirectories: true, attributes: nil)
        } catch {
            #if DEBUG
            print("======FileManagerExtension...makeLogDirectoryIfNeeded...error:\(error)")
            #endif
            reporter.report(error: error)
        }
    }
    
}
