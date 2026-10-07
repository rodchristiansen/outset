//
//  PreferencesTests.swift
//  OutsetTests
//

import Testing
import Foundation

@Suite("OutsetPreferences defaults")
struct OutsetPreferencesTests {

    @Test("Default values are correct")
    func defaultValues() {
        let prefs = OutsetPreferences()
        #expect(prefs.waitForNetwork == false)
        #expect(prefs.networkTimeout == 180)
        #expect(prefs.ignoredUsers.isEmpty)
        #expect(prefs.overrideLoginOnce.isEmpty)
    }

    @Test("CodingKeys use underscore format")
    func codingKeysUseUnderscoreFormat() throws {
        // Encode and check the JSON keys match the expected preference key names
        let prefs = OutsetPreferences()
        let data = try JSONEncoder().encode(prefs)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["wait_for_network"] != nil)
        #expect(json["network_timeout"] != nil)
        #expect(json["ignored_users"] != nil)
        #expect(json["override_login_once"] != nil)
    }

    @Test("Encodes and decodes correctly")
    func roundTrip() throws {
        var prefs = OutsetPreferences()
        prefs.waitForNetwork = true
        prefs.networkTimeout = 300
        prefs.ignoredUsers = ["alice", "bob"]

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(OutsetPreferences.self, from: data)

        #expect(decoded.waitForNetwork == true)
        #expect(decoded.networkTimeout == 300)
        #expect(decoded.ignoredUsers == ["alice", "bob"])
    }
}

@Suite("Preference value parsing")
struct PreferenceValueParsingTests {

    @Test("A false wait_for_network reads as false, not as present")
    func falseBoolIsFalse() {
        #expect(boolPreference(false) == false)
        #expect(boolPreference(NSNumber(value: false)) == false)
        #expect(boolPreference(NSNumber(value: 0)) == false)
        #expect(boolPreference("false") == false)
        #expect(boolPreference("0") == false)
    }

    @Test("True values read as true")
    func trueBoolIsTrue() {
        #expect(boolPreference(true) == true)
        #expect(boolPreference(NSNumber(value: 1)) == true)
        #expect(boolPreference("YES") == true)
    }

    @Test("A missing or unreadable value has no boolean")
    func missingBoolIsNil() {
        #expect(boolPreference(nil) == nil)
        #expect(boolPreference("maybe") == nil)
        #expect(boolPreference(["a"]) == nil)
    }

    @Test("Integers read from numbers and numeric strings")
    func integers() {
        #expect(intPreference(300) == 300)
        #expect(intPreference(NSNumber(value: 45)) == 45)
        #expect(intPreference(" 90 ") == 90)
        #expect(intPreference("ninety") == nil)
        #expect(intPreference(nil) == nil)
    }
}

@Suite("Root preference precedence")
struct RootPreferencePrecedenceTests {

    @Test("A managed value wins over the system file")
    func managedWins() {
        let value = resolvePreferenceValue(isManaged: true, managedValue: { 600 }, systemValue: { 180 })
        #expect(value as? Int == 600)
    }

    @Test("An unmanaged key reads the system file, not the merged value")
    func unmanagedReadsSystemFile() {
        var managedRead = false
        let value = resolvePreferenceValue(
            isManaged: false,
            managedValue: { managedRead = true; return 999 },
            systemValue: { 180 }
        )
        #expect(value as? Int == 180)
        #expect(managedRead == false)
    }

    @Test("No value anywhere leaves the caller's default")
    func absentEverywhere() {
        let value = resolvePreferenceValue(isManaged: false, managedValue: { nil }, systemValue: { nil })
        #expect(value == nil)
        #expect(intPreference(value) ?? 180 == 180)
    }
}

@Suite("Signing key normalisation")
struct SigningKeyNormalisationTests {

    @Test("An empty or blank signing key counts as no key")
    func emptyKeyIsNil() {
        #expect(nonEmpty("") == nil)
        #expect(nonEmpty("  \n") == nil)
        #expect(nonEmpty(nil) == nil)
        #expect(nonEmpty("MCowBQYDK2VwAyEA") == "MCowBQYDK2VwAyEA")
    }
}
