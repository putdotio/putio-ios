import ImageIO
import os
import UniformTypeIdentifiers
import XCTest
@testable import Putio
import PutioSDK

final class MediaPreviewSessionTests: XCTestCase {
    // A preview URL carries the OAuth token, so a cached response would keep it in the cache key.
    func testPreviewResponsesReachNoURLCache() throws {
        let token = "synthetic-token-\(UUID().uuidString)"
        let preview = URLRequest(url: try XCTUnwrap(URL(string: "https://api.put.io/v2/files/1/download?oauth_token=\(token)")))
        let control = URLRequest(url: try XCTUnwrap(URL(string: "https://api.put.io/v2/files/2/download?oauth_token=\(token)")))
        addTeardownBlock {
            URLCache.shared.removeCachedResponse(for: preview)
            URLCache.shared.removeCachedResponse(for: control)
        }

        let configuration = MediaPreviewSession.configuration()
        configuration.protocolClasses = [CacheableResponseURLProtocol.self]
        load(preview, in: URLSession(configuration: configuration))

        // The same response through a default session reaches the shared cache,
        // so by the time it shows up there the preview's would have too.
        let defaultConfiguration = URLSessionConfiguration.default
        defaultConfiguration.protocolClasses = [CacheableResponseURLProtocol.self]
        load(control, in: URLSession(configuration: defaultConfiguration))
        let controlCached = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in URLCache.shared.cachedResponse(for: control) != nil },
            object: nil
        )
        wait(for: [controlCached], timeout: 10)

        XCTAssertNil(URLCache.shared.cachedResponse(for: preview))
    }

    private func load(_ request: URLRequest, in session: URLSession) {
        let finished = expectation(description: "loaded \(request.url?.path ?? "")")
        session.dataTask(with: request) { _, _, error in
            XCTAssertNil(error)
            finished.fulfill()
        }.resume()
        wait(for: [finished], timeout: 10)
    }
}

final class ImagePreviewDecoderTests: XCTestCase {
    func testDecodesWithinTheLimitAndKeepsTheOrientation() throws {
        // Stored 400x200 and tagged rotated 90°, so it shows as 200x400.
        let data = try jpeg(width: 400, height: 200, orientation: .right)
        XCTAssertEqual(UIImage(data: data)?.size, CGSize(width: 200, height: 400))

        let image = try XCTUnwrap(ImagePreviewDecoder.decode(data, maxPixelSize: 100))

        XCTAssertEqual(image.size, CGSize(width: 50, height: 100))
        XCTAssertEqual(image.imageOrientation, .up)
    }

    func testDecodesThePhotoRatherThanItsEmbeddedThumbnail() throws {
        let data = try jpeg(width: 1_200, height: 600, orientation: .up, embedThumbnail: true)
        // Without "from image always", ImageIO hands back the embedded one.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceThumbnailMaxPixelSize: 1_000] as CFDictionary)
        XCTAssertEqual(embedded?.width, 160, "the file should carry a small thumbnail, as camera photos do")

        XCTAssertEqual(ImagePreviewDecoder.decode(data, maxPixelSize: 1_000)?.size, CGSize(width: 1_000, height: 500))
    }

    func testDataThatIsNoImageDecodesToNothing() {
        XCTAssertNil(ImagePreviewDecoder.decode(Data(#"{"error_type":"NotFound"}"#.utf8), maxPixelSize: 100))
    }

    private func jpeg(width: Int, height: Int, orientation: CGImagePropertyOrientation, embedThumbnail: Bool = false) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(UIColor.systemOrange.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation.rawValue,
            kCGImageDestinationEmbedThumbnail: embedThumbnail
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

final class FilePreviewFailureTests: XCTestCase {
    private enum Preview: String, CaseIterable {
        case pdf, image
    }

    private let deleted = "The original version of this file has been deleted from your put.io account."

    func testAMissingDownloadSaysTheFileWasDeleted() throws {
        for preview in Preview.allCases {
            try assertPreview(preview, answeredWith: 404, failsWith: deleted)
        }
    }

    func testAServerErrorSaysTheFetchFailed() throws {
        try assertPreview(.pdf, answeredWith: 500, failsWith: "An error occurred while fetching the PDF")
        try assertPreview(.image, answeredWith: 500, failsWith: "An error occurred while fetching the image")
    }

    private func assertPreview(
        _ preview: Preview,
        answeredWith statusCode: Int,
        failsWith message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fileID = preview == .pdf ? 500_000_001 : 400_000_001
        PreviewDownloadStub.answer(with: statusCode)
        let configuration = MediaPreviewSession.configuration(environment: [:])
        configuration.protocolClasses = [PreviewDownloadStub.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }

        let viewController = try makePreview(preview, fileID: fileID, session: session)
        let navigation = try pushOnWindow(viewController)

        let alert = try waitForAlert(on: viewController, titled: "Oops!")
        XCTAssertEqual(alert.message, message, preview.rawValue, file: file, line: line)
        XCTAssertEqual(alert.actions.map(\.title), ["Go Back"], preview.rawValue, file: file, line: line)
        XCTAssertEqual(PreviewDownloadStub.requestedPaths.last, "/v2/files/\(fileID)/download", preview.rawValue, file: file, line: line)

        try chooseAlertAction("Go Back", in: alert)
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in navigation.topViewController !== viewController }, object: nil)
        wait(for: [returned], timeout: 5)
        XCTAssertEqual(navigation.viewControllers.count, 1, preview.rawValue, file: file, line: line)
    }

    private func makePreview(_ preview: Preview, fileID: Int, session: URLSession) throws -> UIViewController {
        let file = try makeFile(id: fileID, preview: preview)
        switch preview {
        case .pdf:
            let storyboard = UIStoryboard(name: "PDF", bundle: Bundle(for: PDFViewController.self))
            let viewController = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "PDFVC") as? PDFViewController)
            viewController.file = file
            viewController.previewSession = session
            return viewController
        case .image:
            let storyboard = UIStoryboard(name: "Image", bundle: Bundle(for: ImageViewController.self))
            let viewController = try XCTUnwrap(storyboard.instantiateViewController(withIdentifier: "ImageVC") as? ImageViewController)
            viewController.file = file
            viewController.previewSession = session
            return viewController
        }
    }

    private func makeFile(id: Int, preview: Preview) throws -> PutioFile {
        let payload: [String: Any] = [
            "id": id,
            "name": preview == .pdf ? "Document.pdf" : "Photo.jpg",
            "icon": "file",
            "parent_id": 0,
            "file_type": preview == .pdf ? "PDF" : "IMAGE",
            "content_type": preview == .pdf ? "application/pdf" : "image/jpeg",
            "size": 1024,
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z",
            "is_shared": false
        ]
        return try JSONDecoder().decode(PutioFile.self, from: JSONSerialization.data(withJSONObject: payload))
    }
}

private final class PreviewDownloadStub: URLProtocol {
    private static let state = OSAllocatedUnfairLock(initialState: (statusCode: 200, paths: [String]()))

    static var requestedPaths: [String] { state.withLock { $0.paths } }

    static func answer(with statusCode: Int) {
        state.withLock { $0 = (statusCode, []) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let statusCode = Self.state.withLock { state -> Int in
            state.paths.append(url.path)
            return state.statusCode
        }
        guard let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"status":"ERROR","status_code":\#(statusCode)}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Answers every request with a small response any cache may keep for an hour.
private final class CacheableResponseURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Cache-Control": "max-age=3600", "Content-Type": "image/jpeg"]
              )
        else { return }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .allowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0xFF, count: 64))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
