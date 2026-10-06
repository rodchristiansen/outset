//
//  Utils.swift
//  outset
//
//  Created by Bart Reardon on 3/12/2022.
//

import Foundation

func ensureWorkingFolders() {
    // Ensures working folders are all present and creates them if necessary
    let workingDirectories = [
        PayloadType.bootEvery.directoryPath,
        PayloadType.bootOnce.directoryPath,
        PayloadType.loginWindow.directoryPath,
        PayloadType.loginEvery.directoryPath,
        PayloadType.loginOnce.directoryPath,
        PayloadType.loginPrivilegedEvery.directoryPath,
        PayloadType.loginPrivilegedOnce.directoryPath,
        PayloadType.onDemand.directoryPath,
        PayloadType.onDemandPrivileged.directoryPath,
        logDirectory
    ]

    for directory in workingDirectories where !checkDirectoryExists(path: directory) {
        writeLog("\(directory) does not exist, creating now.", logLevel: .debug)
        do {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            writeLog("could not create path at \(directory)", logLevel: .error)
        }
    }
}

func checkFileExists(path: String) -> Bool {
    return FileManager.default.fileExists(atPath: path)
}

func checkDirectoryExists(path: String) -> Bool {
    var isDirectory: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    return isDirectory.boolValue
}

func folderContents(path: String) -> [String] {
    // Returns a array of strings containing the folder contents
    // Does not perform a recursive list
    return getFolderContents(path: path)
}

func folderContents(type: PayloadType) -> [String] {
    // Returns a array of strings containing the folder contents
    // Does not perform a recursive list
    let path = type.directoryPath
    return getFolderContents(path: path)
}

func getFolderContents(path: String) -> [String] {
    var filelist: [String] = []
    do {
        let files = try FileManager.default.contentsOfDirectory(atPath: path)
        let sortedFiles = files.sorted()
        for file in sortedFiles {
            filelist.append("\(path)/\(file)")
        }
    } catch {
        return []
    }
    return filelist
}

func verifyPermissions(pathname: String, trustedOwners: Set<uid_t> = [0]) -> Bool {
    // An item runs only when no account other than root could have changed it:
    // - it is a regular file, never a symlink, so a root-owned link cannot point elsewhere
    // - it is owned by root, mode 644 for packages and profiles, 755 for scripts
    // - every directory above it is root-owned and writable by no group or other,
    //   so the file cannot be swapped between this check and the run
    // trustedOwners exists for tests; outset itself always trusts root only.

    var info = stat()
    guard lstat(pathname, &info) == 0 else {
        writeLog("Could not read file at path \(pathname)", logLevel: .error)
        return false
    }

    guard info.st_mode & S_IFMT == S_IFREG else {
        writeLog("\(pathname) is not a regular file. Symlinks and folders are not run", logLevel: .error)
        return false
    }

    let isPackage = ["pkg", "mpkg", "dmg", "mobileconfig"].contains(pathname.lowercased().split(separator: ".").last)
    let required = isPackage ? FilePermissions.file : FilePermissions.executable
    let mode = info.st_mode & 0o7777

    writeLog("ownerID for \(pathname) : \(info.st_uid)", logLevel: .debug)
    writeLog("posixPermissions for \(pathname) : \(String(mode, radix: 8))", logLevel: .debug)

    guard trustedOwners.contains(info.st_uid), mode == required.rawValue.uint16Value else {
        writeLog("Permissions for \(pathname) are incorrect. Should be owned by root and with mode x\(String(required.rawValue.intValue, radix: 8))", logLevel: .error)
        return false
    }

    return verifyParentChain(of: pathname, trustedOwners: trustedOwners)
}

func verifyParentChain(of pathname: String, trustedOwners: Set<uid_t> = [0]) -> Bool {
    // Walks from the item's real parent directory up to /, requiring each one to be a
    // directory owned by a trusted owner and not writable by group or other.
    let parent = (pathname as NSString).deletingLastPathComponent
    guard let resolved = realpath(parent, nil) else {
        writeLog("Could not resolve the folder holding \(pathname)", logLevel: .error)
        return false
    }
    var directory = String(cString: resolved)
    free(resolved)

    while true {
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            writeLog("Could not read folder \(directory) above \(pathname)", logLevel: .error)
            return false
        }
        guard trustedOwners.contains(info.st_uid), info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            writeLog("Folder \(directory) above \(pathname) must be owned by root and writable only by root. Skipping", logLevel: .error)
            return false
        }
        if directory == "/" { return true }
        directory = (directory as NSString).deletingLastPathComponent
    }
}

func pathCleanup(_ pathname: String) {
    // check if folder and clean all files in that folder
    // Deletes given script or cleans folder
    writeLog("Cleaning up \(pathname)", logLevel: .debug)
    if checkDirectoryExists(path: pathname) {
        for fileItem in folderContents(path: pathname) {
            writeLog("Cleaning up \(fileItem)", logLevel: .debug)
            deletePath(fileItem)
        }
    } else if checkFileExists(path: pathname) {
        writeLog("\(pathname) exists", logLevel: .debug)
        deletePath(pathname)
    } else {
        writeLog("\(pathname) doesn't seem to exist", logLevel: .error)
    }
}

func deletePath(_ path: String) {
    // Deletes the specified file
    writeLog("Deleting \(path)", logLevel: .debug)
    do {
        try FileManager.default.removeItem(atPath: path)
        writeLog("\(path) deleted", logLevel: .debug)
    } catch {
        writeLog("\(path) could not be removed", logLevel: .error)
    }
}

func createTrigger(_ path: String) {
    FileManager.default.createFile(atPath: path, contents: nil)
}
