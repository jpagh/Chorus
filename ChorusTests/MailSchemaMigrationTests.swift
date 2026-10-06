import SwiftData
import XCTest
@testable import Chorus

@MainActor
final class MailSchemaMigrationTests: XCTestCase {
    func testShippedPreMailStoreKeepsAccountAndStartsWithoutApprovedHandler() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "chorus-mail-migration-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "default.store")
        let serviceID = UUID(), storeID = UUID(), spaceID = UUID(), linkID = UUID()
        try autoreleasepool {
            let schema = Schema(versionedSchema: ChorusSchemaV1_5_19.self)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            let service = ChorusSchemaV1_5_19.ServiceInstance(id: serviceID, label: "Work mail", url: "https://mail.example.test/inbox")
            service.dataStoreIdentifier = storeID
            service.stayActiveInBackground = false
            service.hibernationPolicyRaw = "after"
            service.hibernateAfterMinutes = 17
            service.userAgent = "FixtureBrowser/1.0"
            let space = ChorusSchemaV1_5_19.Space(id: spaceID, name: "Work", emoji: "", sortOrder: 2)
            container.mainContext.insert(service)
            container.mainContext.insert(space)
            try container.mainContext.save()
            let link = ChorusSchemaV1_5_19.SpaceServiceLink(id: linkID, sortOrder: 3, space: space, service: service)
            if link.modelContext == nil { container.mainContext.insert(link) }
            try container.mainContext.save()
        }
        let schema = Schema(versionedSchema: ChorusSchemaVCurrent.self)
        let container = try ModelContainer(for: schema, migrationPlan: ChorusMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url))
        let services = try container.mainContext.fetch(FetchDescriptor<ServiceInstance>())
        XCTAssertEqual(services.count, 1)
        let service = try XCTUnwrap(services.first)
        XCTAssertEqual(service.id, serviceID)
        XCTAssertEqual(service.dataStoreIdentifier, storeID)
        XCTAssertEqual(service.label, "Work mail")
        XCTAssertEqual(service.url, "https://mail.example.test/inbox")
        XCTAssertEqual(service.userAgent, "FixtureBrowser/1.0")
        XCTAssertEqual(service.hibernateAfterMinutes, 17)
        XCTAssertEqual(service.stayActiveInBackground, false)
        XCTAssertNil(service.mailtoHandler)
        XCTAssertNil(service.mailtoHandlerEnabled)
        let links = try container.mainContext.fetch(FetchDescriptor<SpaceServiceLink>())
        XCTAssertEqual(links.count, 1)
        let link = try XCTUnwrap(links.first)
        XCTAssertEqual(link.id, linkID)
        XCTAssertEqual(link.service?.id, serviceID)
        XCTAssertEqual(link.space?.id, spaceID)
    }
}
