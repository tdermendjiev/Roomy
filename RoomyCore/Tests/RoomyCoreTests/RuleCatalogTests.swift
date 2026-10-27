import Foundation
import Testing
@testable import RoomyCore

struct RuleCatalogTests {
    @Test func builtinCatalogLoadsAndValidates() throws {
        let c = RuleCatalog.builtin
        #expect(c.schemaVersion == 1)
        #expect(c.projectRules.count > 20)
        #expect(c.systemRules.count > 40)
        try c.validate()
    }

    @Test func everyBuiltinSystemRuleHasAtLeastOnePlatform() {
        for r in RuleCatalog.builtin.systemRules {
            #expect(!r.paths.isEmpty, "rule \(r.id) has no paths")
            #expect(RoomySystemScanCategories.allKeys.contains(r.category), "rule \(r.id) has unknown category \(r.category)")
        }
    }

    @Test func mergeOverridesByIDAndAppendsNew() throws {
        let custom = RuleCatalog(catalogVersion: "test", projectRules: [
            ProjectArtifactRule(id: "node_modules", folderName: "node_modules", label: "nm", ecosystem: "npm", tier: .caution),
            ProjectArtifactRule(id: "custom-out", folderName: "out", label: "out", ecosystem: "general"),
        ], systemRules: [])
        let merged = RuleCatalog.builtin.merged(with: custom)
        #expect(merged.projectRules.first { $0.id == "node_modules" }?.tier == .caution)
        #expect(merged.projectRules.contains { $0.id == "custom-out" })
        #expect(merged.projectRules.count == RuleCatalog.builtin.projectRules.count + 1)
    }

    @Test func duplicateIDsAreRejected() {
        let json = """
        {"projectRules":[{"id":"a","folderName":"x"},{"id":"a","folderName":"y"}]}
        """.data(using: .utf8)!
        #expect(throws: RuleCatalogError.duplicateID("a")) { try RuleCatalog.decode(json) }
    }

    @Test func newerSchemaIsRejected() {
        let json = #"{"schemaVersion": 99, "projectRules": [], "systemRules": []}"#.data(using: .utf8)!
        #expect(throws: RuleCatalogError.unsupportedSchema(99)) { try RuleCatalog.decode(json) }
    }

    @Test func removingRulesWorks() {
        let c = RuleCatalog.builtin.removing(ruleIDs: ["node_modules", "ollama-models"])
        #expect(!c.projectRules.contains { $0.id == "node_modules" })
        #expect(!c.systemRules.contains { $0.id == "ollama-models" })
    }

    @Test func roundTripsThroughJSON() throws {
        let data = try RuleCatalog.builtin.encoded()
        let again = try RuleCatalog.decode(data)
        #expect(again == RuleCatalog.builtin)
    }
}
