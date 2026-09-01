//
//  LoggingTests.swift
//  OutsetTests
//

import Testing
import Foundation
import OSLog

@Suite("logFileLevel")
struct LogFileLevelTests {

    @Test("Maps OSLogType onto the log file level vocabulary")
    func mapsLevels() {
        #expect(logFileLevel(.default) == "INFO")
        #expect(logFileLevel(.info) == "INFO")
        #expect(logFileLevel(.debug) == "DEBUG")
        #expect(logFileLevel(.error) == "ERROR")
        #expect(logFileLevel(.fault) == "ERROR")
    }
}

@Suite("formatLogFileLine")
struct FormatLogFileLineTests {

    private var fixedDate: Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 1
        components.hour = 13
        components.minute = 15
        components.second = 14
        return Calendar.current.date(from: components)!
    }

    @Test("Pads the level to five characters after a bracketed local timestamp")
    func formatsInfoLine() {
        let line = formatLogFileLine("Processing boot-every scripts", logLevel: .info, date: fixedDate)
        #expect(line == "[2026-09-01 13:15:14] INFO  Processing boot-every scripts")
    }

    @Test("Five character levels are followed by a single space")
    func formatsErrorLine() {
        let line = formatLogFileLine("Unable to connect to network", logLevel: .fault, date: fixedDate)
        #expect(line == "[2026-09-01 13:15:14] ERROR Unable to connect to network")
    }
}
