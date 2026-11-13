import Testing

@testable import PraticoCore

@Test func emptyFileGivesDefaults() throws {
    let c = try Config.parse("")
    #expect(c.startAtLogin)
    #expect(c.defaultCPUs == 4)
    #expect(c.defaultMemoryMiB == 1024)
    #expect(c.overrides.isEmpty)
}

@Test func overridesWithCommentsAndUnderscores() throws {
    let c = try Config.parse("""
        # pratico
        default_memory = 2_048  # MiB
        start_at_login = false
        """)
    #expect(c.defaultMemoryMiB == 2048)
    #expect(!c.startAtLogin)
    #expect(c.overrides.count == 2)
}

@Test func unknownKeyNamesKeyAndLine() {
    #expect(throws: Config.ParseError(line: 2, key: "bogus_key", message: "unknown key")) {
        try Config.parse("default_cpus = 2\nbogus_key = 1\n")
    }
}

@Test func invalidValueNamesKeyAndLine() {
    let e = #expect(throws: Config.ParseError.self) { try Config.parse("start_at_login = yes") }
    #expect(e?.line == 1)
    #expect(e?.key == "start_at_login")
}

@Test func outOfRangeIsInvalid() {
    #expect(throws: Config.ParseError.self) { try Config.parse("default_cpus = 0") }
}

@Test func duplicateAndTablesRejected() {
    #expect(throws: Config.ParseError.self) { try Config.parse("default_cpus = 2\ndefault_cpus = 3") }
    #expect(throws: Config.ParseError.self) { try Config.parse("[general]\ndefault_cpus = 2") }
}

@Test func errorDescriptionMentionsKeyAndLine() {
    let e = Config.ParseError(line: 3, key: "bogus_key", message: "unknown key")
    #expect(e.description == "config.toml line 3: `bogus_key`: unknown key")
}

@Test func scanKeysDefaultAndParse() throws {
    let d = try Config.parse("")
    #expect(d.scan && d.scanBlock == "kev" && d.scanAllow.isEmpty)
    let c = try Config.parse("""
        scan_block = "critical"
        scan_allow = ["sha256:abc", "sha256:d,e"]  # trailing comment
        """)
    #expect(c.scanBlock == "critical")
    #expect(c.scanAllow == ["sha256:abc", "sha256:d,e"])
    #expect(throws: Config.ParseError.self) { try Config.parse(#"scan_block = "sometimes""#) }
    #expect(throws: Config.ParseError.self) { try Config.parse(#"scan_allow = "sha256:abc""#) }
}

@Test func settingWritesOnlyThatKeyAndKeepsComments() throws {
    // AC-37: from no file, one change writes one key.
    #expect(try Config.setting("default_memory", to: .int(2048), in: "") == "default_memory = 2048\n")
    let text = """
        # mine
        scan = false  # quiet
        registry_http = ["a"]
        """
    let changed = try Config.setting("registry_http", to: .strings(["a", "10.0.0.0/8"]), in: text)
    #expect(changed == "# mine\nscan = false  # quiet\nregistry_http = [\"a\", \"10.0.0.0/8\"]\n")
    #expect(try Config.parse(changed).registryHTTP == ["a", "10.0.0.0/8"])
    #expect(try Config.setting("scan", to: nil, in: text) == "# mine\nregistry_http = [\"a\"]\n")
    #expect(try Config.setting("registry_keep_logins", to: .bool(false), in: text).hasSuffix("registry_keep_logins = false\n"))
    #expect(throws: Config.ParseError.self) { try Config.setting("default_cpus", to: .int(999), in: "") }
}
