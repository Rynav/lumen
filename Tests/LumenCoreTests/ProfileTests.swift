import Foundation
import XCTest
@testable import LumenCore

final class ProfileTests: XCTestCase {
    func testProfileRoundTripPersistsOnlyMetadataAndPricing() throws {
        for kind in ProviderKind.allCases {
            let profile = ProviderProfile(
                name: "Test", kind: kind, baseURL: "http://localhost:11434/v1",
                defaultModel: "test-model", inputPricePerMillion: 1.25, outputPricePerMillion: 5
            )
            let data = try JSONEncoder().encode(profile)
            XCTAssertEqual(try JSONDecoder().decode(ProviderProfile.self, from: data), profile)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(Set(object.keys), Set([
                "id", "name", "kind", "baseURL", "defaultModel",
                "inputPricePerMillion", "outputPricePerMillion"
            ]))
        }
    }

    func testProfileWithoutPricingDecodes() throws {
        let id = UUID()
        let data = Data("""
        {"id":"\(id.uuidString)","name":"Local","kind":"compatible",
         "baseURL":"http://localhost:11434/v1","defaultModel":"local"}
        """.utf8)
        let profile = try JSONDecoder().decode(ProviderProfile.self, from: data)
        XCTAssertEqual(profile.id, id)
        XCTAssertNil(profile.inputPricePerMillion)
        XCTAssertNil(profile.outputPricePerMillion)
    }
}
