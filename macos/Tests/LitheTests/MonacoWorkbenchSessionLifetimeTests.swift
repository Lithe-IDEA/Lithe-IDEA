import AppKit
import Testing
import WebKit
@testable import Lithe

@Suite("Monaco document session lifetime")
@MainActor
struct MonacoWorkbenchSessionLifetimeTests {
    @Test func movingDocumentBetweenMountsRetainsItsNativeEditor() throws {
        let project = UUID(), document = UUID()
        let session = MonacoWorkbenchSession.forModel(project, documentID: document)
        let firstOwner = UUID(), secondOwner = UUID()
        let first = session.makeContainer(ownerID: firstOwner, isPreview: false)
        let original = try #require(first.subviews.first as? WKWebView)
        let reused = MonacoWorkbenchSession.forModel(project, documentID: document)
        #expect(reused === session)
        let second = reused.makeContainer(ownerID: secondOwner, isPreview: false)
        defer {
            session.detachView(ownerID: firstOwner)
            session.detachView(ownerID: secondOwner)
            original.stopLoading()
        }
        #expect(second.subviews.first === original)
        #expect(first.subviews.isEmpty)
        session.detachView(ownerID: firstOwner)
        #expect(second.subviews.first === original, "Late source teardown must not detach the moved editor")
        #expect(MonacoWorkbenchSession.forModel(project, documentID: UUID()) !== session)
        #expect(MonacoWorkbenchSession.forModel(UUID(), documentID: document) !== session)
    }
}
