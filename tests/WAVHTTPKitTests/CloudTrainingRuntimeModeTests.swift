import XCTest
@testable import WAVHTTPKit

@MainActor
final class CloudTrainingRuntimeModeTests: XCTestCase {
    func testMockModelCanSwitchToExplicitRealHTTPAndBackOnlyWhileIdle() throws {
        let model = CloudTrainingModel.mock()
        XCTAssertTrue(model.isMock)

        try model.useRealBackend(
            baseURL: URL(string: "https://api.fitcore.example")!,
            accessToken: "demo-token"
        )

        XCTAssertFalse(model.isMock)
        XCTAssertEqual(model.client.configuration.baseURL.absoluteString, "https://api.fitcore.example")
        XCTAssertEqual(model.client.configuration.accessToken, "demo-token")
        XCTAssertFalse(model.client.transport is MockCloudBackend)

        try model.useMockBackend()
        XCTAssertTrue(model.isMock)
        XCTAssertTrue(model.client.transport is MockCloudBackend)
    }

    func testRuntimeModeCannotChangeAfterSessionCreationStarts() throws {
        let model = CloudTrainingModel.mock()
        model.createSession()

        XCTAssertThrowsError(
            try model.useRealBackend(
                baseURL: URL(string: "https://api.fitcore.example")!,
                accessToken: "demo-token"
            )
        ) { error in
            XCTAssertEqual(error as? CloudTrainingModel.RuntimeModeError, .sessionActive)
        }
    }

    func testRealHTTPModeReusesBackendConfigurationValidation() {
        let model = CloudTrainingModel.mock()

        XCTAssertThrowsError(
            try model.useRealBackend(
                baseURL: URL(string: "http://api.fitcore.example")!,
                accessToken: "demo-token"
            )
        ) { error in
            XCTAssertEqual(error as? BackendHTTPConfiguration.ValidationError, .invalidBaseURL)
        }

        XCTAssertThrowsError(
            try model.useRealBackend(
                baseURL: URL(string: "https://api.fitcore.example")!,
                accessToken: "   "
            )
        ) { error in
            XCTAssertEqual(error as? BackendHTTPConfiguration.ValidationError, .invalidToken)
        }
    }
}
