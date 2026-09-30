import Foundation
import XCTest

@testable import PutioCore

extension PutioRuntimeTests {
  private static let filesContinueRoute = "POST /v2/files/list/continue"
  private static let searchRoute = "GET /v2/files/search"
  private static let searchContinueRoute = "POST /v2/files/search/continue"
  private static let setSortRoute = "POST /v2/files/set-sort-by"
  private static let createFolderRoute = "POST /v2/files/create-folder"
  private static let renameFileRoute = "POST /v2/files/rename"
  private static let moveFilesRoute = "POST /v2/files/move"
  private static let deleteFilesRoute = "POST /v2/files/delete"

  func testUnauthenticatedRuntimeRejectsListingWithoutARequest() async {
    let (runtime, _) = makeRuntime(token: nil)

    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.listFiles()
    }
    await runtime.session.restore()
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.listFiles()
    }

    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
  }

  func testListMapsAppOwnedValuesAndKeepsCursorAndSort() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      Self.filesList(cursor: "next-page", sortBy: "DATE_DESC"), for: Self.filesRoute)

    let contents = try await runtime.listFiles(parentID: .root)

    XCTAssertEqual(contents.folder?.id, .root)
    XCTAssertEqual(contents.folder?.name, "Your Files")
    XCTAssertEqual(contents.folder?.kind, .folder)
    XCTAssertEqual(contents.nextCursor, "next-page")
    XCTAssertTrue(contents.hasMore)
    XCTAssertEqual(contents.sort, .dateAddedDescending)
    XCTAssertEqual(
      contents.items.map(\.kind),
      [.video, .audio, .image, .pdf, .folder, .other("ARCHIVE")]
    )

    let video = try XCTUnwrap(contents.items.first)
    XCTAssertEqual(video.id, PutioFileID(rawValue: 11))
    XCTAssertEqual(video.parentID, .root)
    XCTAssertEqual(video.name, "Episode 1.mkv")
    XCTAssertEqual(video.sizeBytes, 1_024)
    XCTAssertEqual(video.resumePositionSeconds, 42)
    XCTAssertTrue(video.isWatched)
    XCTAssertEqual(
      video.createdAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-28T10:00:00Z"))
    )
    XCTAssertEqual(
      video.updatedAt,
      try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-29T10:00:00Z"))
    )

    let description = String(reflecting: contents)
    XCTAssertFalse(description.contains("stream-secret"))
    XCTAssertFalse(description.contains("mp4-secret"))
  }

  func testNilAndEmptyCursorsDoNotClaimContinuation() async throws {
    let (runtime, _) = await makeSignedInRuntime()

    fixtures.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    let nilCursorContents = try await runtime.listFiles()
    XCTAssertNil(nilCursorContents.nextCursor)
    XCTAssertFalse(nilCursorContents.hasMore)

    fixtures.setFixture(Self.filesList(cursor: ""), for: Self.filesRoute)
    let emptyCursorContents = try await runtime.listFiles()
    XCTAssertNil(emptyCursorContents.nextCursor)
    XCTAssertFalse(emptyCursorContents.hasMore)
  }

  func testUnknownAndMissingSortKeysMapToNil() async throws {
    let (runtime, _) = await makeSignedInRuntime()

    fixtures.setFixture(
      Self.filesList(cursor: nil, sortBy: "FUTURE_KEY"), for: Self.filesRoute)
    let unknownSort = try await runtime.listFiles().sort
    XCTAssertNil(unknownSort)

    fixtures.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)
    let missingSort = try await runtime.listFiles().sort
    XCTAssertNil(missingSort)
  }

  func testContinueFilesPostsTheCursorAndAppendsNothingItself() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"cursor":"","files":[{"id":31,"name":"Page 2.mkv","file_type":"VIDEO","parent_id":0,"size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}]}"#,
      for: Self.filesContinueRoute
    )

    let page = try await runtime.continueFiles(cursor: "files-page-2")

    XCTAssertNil(page.folder)
    XCTAssertNil(page.nextCursor)
    XCTAssertEqual(page.items.map(\.id), [PutioFileID(rawValue: 31)])
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/list/continue")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["cursor"] as? String, "files-page-2")
  }

  func testContinueFilesRejectsANonadvancingCursor() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"cursor":"files-page-2","files":[]}"#, for: Self.filesContinueRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.continueFiles(cursor: "files-page-2")
    }
  }

  func testSearchEncodesQueryAndMapsAppOwnedResults() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"total":2,"cursor":"search-page-2","files":[{"id":31,"name":"Summer & snow.mkv","file_type":"VIDEO","parent_id":42,"size":1024,"start_from":12,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z","stream_url":"https://example.com/stream-secret"}]}"#,
      for: Self.searchRoute
    )

    let query = "Summer & snow + 東京?"
    let page = try await runtime.searchFiles(query: query)

    XCTAssertEqual(page.totalCount, 2)
    XCTAssertEqual(page.nextCursor, "search-page-2")
    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.id, PutioFileID(rawValue: 31))
    XCTAssertEqual(item.parentID, PutioFileID(rawValue: 42))
    XCTAssertEqual(item.name, "Summer & snow.mkv")
    XCTAssertEqual(item.kind, .video)
    XCTAssertEqual(item.sizeBytes, 1024)
    XCTAssertEqual(item.resumePositionSeconds, 12)
    XCTAssertFalse(String(reflecting: page).contains("stream-secret"))
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.url?.path, "/v2/files/search")
    let components = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
    )
    XCTAssertEqual(components.queryItems?.first { $0.name == "query" }?.value, query)
    XCTAssertEqual(components.queryItems?.first { $0.name == "per_page" }?.value, "50")
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization")?.lowercased(), "token stored-token")
  }

  func testSearchContinuationPostsOpaqueCursorAndMapsFinalPage() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"total":2,"cursor":"","files":[{"id":32,"name":"Page 2.mkv","file_type":"VIDEO","parent_id":42,"size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}]}"#,
      for: Self.searchContinueRoute
    )

    let cursor = "opaque+/= search cursor"
    let page = try await runtime.continueFileSearch(cursor: cursor)

    XCTAssertEqual(page.totalCount, 2)
    XCTAssertNil(page.nextCursor)
    XCTAssertEqual(page.items.map(\.id), [PutioFileID(rawValue: 32)])
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/search/continue")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["cursor"] as? String, cursor)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Authorization")?.lowercased(), "token stored-token")
  }

  func testSearchRejectsNegativeTotalsAndNonadvancingContinuation() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"total":-1,"files":[]}"#, for: Self.searchRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.searchFiles(query: "video")
    }
    fixtures.setFixture(
      #"{"total":3,"cursor":"same-page","files":[]}"#, for: Self.searchContinueRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.continueFileSearch(cursor: "same-page")
    }
    fixtures.setFixture(#"{"total":0,"files":[]}"#, for: Self.searchRoute)
    let emptyPage = try await runtime.searchFiles(query: "missing")
    XCTAssertEqual(emptyPage, PutioFileSearchPage(items: [], nextCursor: nil, totalCount: 0))
  }

  func testUnauthenticatedRuntimeRejectsSearchAndContinuationWithoutRequests() async {
    let (runtime, _) = makeRuntime(token: nil)
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.searchFiles(query: "video")
    }
    await assertRuntimeError(.authenticationRequired) {
      _ = try await runtime.continueFileSearch(cursor: "next-page")
    }
    XCTAssertTrue(fixtures.capturedRequests().isEmpty)
  }

  func testSearchAuthenticationFailuresExpireSessionAndBlockFurtherRequests() async {
    for route in [Self.searchRoute, Self.searchContinueRoute] {
      fixtures.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      fixtures.setFixture(
        #"{"status":"ERROR","error_type":"invalid_grant"}"#, statusCode: 401, for: route)
      await assertRuntimeError(.sessionExpired) {
        if route == Self.searchRoute {
          _ = try await runtime.searchFiles(query: "video")
        } else {
          _ = try await runtime.continueFileSearch(cursor: "next-page")
        }
      }
      XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
      XCTAssertNil(try? tokenStore.read())
      let requestCount = fixtures.capturedRequests().count
      await assertRuntimeError(.sessionExpired) {
        _ = try await runtime.searchFiles(query: "video")
      }
      XCTAssertEqual(fixtures.capturedRequests().count, requestCount)
    }
  }

  func testFileLookupMapsAuthoritativeFileAndRejectsWrongIdentity() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    let route = "GET /v2/files/410"
    let fixture =
      #"{"file":{"id":410,"name":"Folder","file_type":"FOLDER","parent_id":42,"size":0,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#
    fixtures.setFixture(fixture, for: route)
    let file = try await runtime.getFile(fileID: PutioFileID(rawValue: 410))
    XCTAssertEqual(file.kind, .folder)
    XCTAssertEqual(file.parentID, PutioFileID(rawValue: 42))
    fixtures.setFixture(
      fixture.replacingOccurrences(of: "410", with: "411"), for: route)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.getFile(fileID: PutioFileID(rawValue: 410))
    }
    fixtures.setFixture(#"{"status":"ERROR"}"#, statusCode: 404, for: route)
    await assertRuntimeError(.notFound) {
      _ = try await runtime.getFile(fileID: PutioFileID(rawValue: 410))
    }
  }

  func testSetFolderSortPostsTheServerKey() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.setSortRoute)

    try await runtime.setFolderSort(folderID: PutioFileID(rawValue: 42), sort: .sizeDescending)

    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.url?.path, "/v2/files/set-sort-by")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["file_id"] as? Int, 42)
    XCTAssertEqual(json["sort_by"] as? String, "SIZE_DESC")
  }

  func testListSendsTheRequestedParentID() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(Self.filesList(cursor: nil), for: Self.filesRoute)

    _ = try await runtime.listFiles(parentID: PutioFileID(rawValue: 42))

    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    let components = try XCTUnwrap(
      request.url.flatMap {
        URLComponents(url: $0, resolvingAgainstBaseURL: false)
      }
    )
    XCTAssertEqual(
      components.queryItems?.first(where: { $0.name == "parent_id" })?.value,
      "42"
    )
  }

  func testFileActionsUseSDKOwnedRoutesAndMapCreatedFolder() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {
        "file": {
          "id": 91,
          "name": "Season 2",
          "file_type": "FOLDER",
          "parent_id": 7,
          "size": 0,
          "created_at": "2026-09-01T10:00:00Z",
          "updated_at": "2026-09-01T10:00:00Z"
        }
      }
      """,
      for: Self.createFolderRoute
    )
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.renameFileRoute)
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.deleteFilesRoute)

    let folder = try await runtime.createFolder(
      name: "Season 2",
      parentID: PutioFileID(rawValue: 7)
    )
    try await runtime.renameFile(fileID: folder.id, name: "Season Two")
    try await runtime.deleteFile(fileID: folder.id)

    XCTAssertEqual(folder.id, PutioFileID(rawValue: 91))
    XCTAssertEqual(folder.parentID, PutioFileID(rawValue: 7))
    XCTAssertEqual(folder.name, "Season 2")
    XCTAssertEqual(folder.kind, .folder)

    let actionRequests = fixtures.capturedRequests().suffix(3)
    XCTAssertEqual(
      actionRequests.compactMap { $0.url?.path },
      ["/v2/files/create-folder", "/v2/files/rename", "/v2/files/delete"]
    )
    let bodies = try actionRequests.map { request -> [String: Any] in
      let data = try XCTUnwrap(requestBodyData(for: request))
      return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    XCTAssertEqual(bodies[0]["name"] as? String, "Season 2")
    XCTAssertEqual(bodies[0]["parent_id"] as? Int, 7)
    XCTAssertEqual(bodies[1]["file_id"] as? Int, 91)
    XCTAssertEqual(bodies[1]["name"] as? String, "Season Two")
    XCTAssertEqual(bodies[2]["file_ids"] as? String, "91")
  }

  func testMoveFileUsesSingleItemSDKRequestAndAcceptsAnEmptyErrorList() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"OK","errors":[]}"#,
      for: Self.moveFilesRoute
    )

    try await runtime.moveFile(
      fileID: PutioFileID(rawValue: 91),
      to: PutioFileID(rawValue: 7)
    )

    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v2/files/move")
    let body = try XCTUnwrap(requestBodyData(for: request))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["file_ids"] as? String, "91")
    XCTAssertEqual(json["parent_id"] as? Int, 7)
  }

  func testMoveFileMapsAReportedItemFailureWithoutExpiringTheSession() async {
    let cases: [(Int, PutioRuntimeError)] = [
      (403, .unknown),
      (404, .notFound),
      (408, .transient),
      (429, .rateLimited),
      (500, .transient),
    ]

    for (statusCode, expected) in cases {
      fixtures.reset()
      let (runtime, tokenStore) = await makeSignedInRuntime()
      fixtures.setFixture(
        """
        {
          "status": "OK",
          "errors": [
            {
              "error_type": "MOVE_FAILED",
              "id": 91,
              "name": "Season 2",
              "status_code": \(statusCode)
            }
          ]
        }
        """,
        for: Self.moveFilesRoute
      )

      await assertRuntimeError(expected) {
        try await runtime.moveFile(
          fileID: PutioFileID(rawValue: 91),
          to: PutioFileID(rawValue: 7)
        )
      }

      guard case .signedIn = runtime.session.state else {
        return XCTFail("a structured item failure must preserve the signed-in session")
      }
      XCTAssertEqual(try? tokenStore.read(), "stored-token")
    }
  }

  func testMoveFileRejectsContradictoryOrMismatchedStructuredResponses() async {
    let (runtime, _) = await makeSignedInRuntime()
    let responses = [
      #"{"status":"ERROR","errors":[]}"#,
      """
      {
        "status": "OK",
        "errors": [
          {
            "error_type": "MOVE_FAILED",
            "id": 92,
            "status_code": 404
          }
        ]
      }
      """,
    ]

    for response in responses {
      fixtures.setFixture(response, for: Self.moveFilesRoute)
      await assertRuntimeError(.invalidResponse) {
        try await runtime.moveFile(
          fileID: PutioFileID(rawValue: 91),
          to: PutioFileID(rawValue: 7)
        )
      }
    }
  }

  func testListFoldersRequestsOnlyFoldersAndHidesTheSharedRoot() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {
        "cursor": "folders-next",
        "parent": {
          "id": 0, "name": "Your Files", "file_type": "FOLDER", "parent_id": 0, "size": 0,
          "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"
        },
        "files": [
          {
            "id": 21, "name": "Movies", "file_type": "FOLDER", "parent_id": 0, "size": 0,
            "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"
          },
          {
            "id": 22, "name": "items shared with you", "file_type": "FOLDER",
            "folder_type": "SHARED_ROOT", "parent_id": 0, "size": 0,
            "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"
          }
        ]
      }
      """,
      for: Self.filesRoute
    )

    let contents = try await runtime.listFolders(parentID: PutioFileID(rawValue: 42))

    XCTAssertEqual(contents.items.map(\.id), [PutioFileID(rawValue: 21)])
    XCTAssertEqual(contents.nextCursor, "folders-next")
    let request = try XCTUnwrap(fixtures.capturedRequests().last)
    let query = try XCTUnwrap(
      request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems)
    XCTAssertEqual(query.first(where: { $0.name == "file_type" })?.value, "FOLDER")
    XCTAssertEqual(query.first(where: { $0.name == "parent_id" })?.value, "42")
  }

  func testFolderContinuationStillHidesTheSharedRoot() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {
        "cursor": "",
        "files": [
          {
            "id": 23, "name": "Shows", "file_type": "FOLDER", "parent_id": 0, "size": 0,
            "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"
          },
          {
            "id": 22, "name": "items shared with you", "file_type": "FOLDER",
            "folder_type": "SHARED_ROOT", "parent_id": 0, "size": 0,
            "created_at": "2026-08-01T10:00:00Z", "updated_at": "2026-08-01T10:00:00Z"
          }
        ]
      }
      """,
      for: Self.filesContinueRoute
    )

    let page = try await runtime.continueFolders(cursor: "folders-next")

    XCTAssertEqual(page.items.map(\.id), [PutioFileID(rawValue: 23)])
    XCTAssertNil(page.nextCursor)
  }

  func testMoveFilesSendsOneBatchAndMapsEachReportedFailure() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      """
      {
        "status": "OK",
        "errors": [
          { "error_type": "MOVE_FAILED", "id": 92, "status_code": 404 },
          { "error_type": "MOVE_FAILED", "id": 93, "status_code": 429 }
        ]
      }
      """,
      for: Self.moveFilesRoute
    )

    let failures = try await runtime.moveFiles(
      fileIDs: [91, 92, 93].map(PutioFileID.init(rawValue:)),
      to: PutioFileID(rawValue: 7)
    )

    XCTAssertEqual(
      failures,
      [PutioFileID(rawValue: 92): .notFound, PutioFileID(rawValue: 93): .rateLimited])
    let moveRequests = fixtures.capturedRequests().filter { $0.url?.path == "/v2/files/move" }
    XCTAssertEqual(moveRequests.count, 1)
    let body = try XCTUnwrap(requestBodyData(for: try XCTUnwrap(moveRequests.first)))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["file_ids"] as? String, "91,92,93")
    XCTAssertEqual(json["parent_id"] as? Int, 7)

    fixtures.setFixture(
      #"{"status":"OK","errors":[{"error_type":"MOVE_FAILED","id":99,"status_code":404}]}"#,
      for: Self.moveFilesRoute)
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.moveFiles(
        fileIDs: [PutioFileID(rawValue: 91)], to: PutioFileID(rawValue: 7))
    }
  }

  func testDeleteFilesSendsOneBatch() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(#"{"status":"OK"}"#, for: Self.deleteFilesRoute)

    try await runtime.deleteFiles(fileIDs: [91, 92].map(PutioFileID.init(rawValue:)))

    let deleteRequests = fixtures.capturedRequests().filter { $0.url?.path == "/v2/files/delete" }
    XCTAssertEqual(deleteRequests.count, 1)
    let body = try XCTUnwrap(requestBodyData(for: try XCTUnwrap(deleteRequests.first)))
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(json["file_ids"] as? String, "91,92")

    // A 2xx envelope that reports failure must not read as a deleted batch.
    fixtures.setFixture(#"{"status":"ERROR"}"#, for: Self.deleteFilesRoute)
    await assertRuntimeError(.invalidResponse) {
      try await runtime.deleteFiles(fileIDs: [PutioFileID(rawValue: 91)])
    }
  }

  func testMoveFileAuthenticationFailureUsesTheSharedSessionBoundary() async {
    let (runtime, tokenStore) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"status":"ERROR","error_type":"invalid_grant"}"#,
      statusCode: 401,
      for: Self.moveFilesRoute
    )

    await assertRuntimeError(.sessionExpired) {
      try await runtime.moveFile(
        fileID: PutioFileID(rawValue: 91),
        to: PutioFileID(rawValue: 7)
      )
    }

    XCTAssertEqual(runtime.session.state, .signedOut(.sessionExpired))
    XCTAssertNil(try? tokenStore.read())
  }

  func testFileDownloadSourceCarriesTheTokenedURLAndRedactsIt() async throws {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file":{"id":440,"parent_id":7,"name":"Poster.png","file_type":"IMAGE","size":10,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/440")

    let source = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 440))

    XCTAssertEqual(source.id, PutioFileID(rawValue: 440))
    XCTAssertEqual(source.kind, .image)
    XCTAssertEqual(source.name, "Poster.png")
    XCTAssertEqual(source.url.path, "/v2/files/440/download")
    XCTAssertEqual(source.url.query?.contains("oauth_token=stored-token"), true)
    XCTAssertFalse(String(describing: source).contains("stored-token"))
    XCTAssertFalse(String(reflecting: source).contains("stored-token"))
  }

  func testFileDownloadSourceRejectsFoldersAndMismatchedIDs() async {
    let (runtime, _) = await makeSignedInRuntime()
    fixtures.setFixture(
      #"{"file":{"id":441,"parent_id":0,"name":"Folder","file_type":"FOLDER","size":0,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/441")
    fixtures.setFixture(
      #"{"file":{"id":9,"parent_id":0,"name":"Other.png","file_type":"IMAGE","size":1,"created_at":"2026-08-28T10:00:00Z","updated_at":"2026-08-29T10:00:00Z"}}"#,
      for: "GET /v2/files/442")

    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 441))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: PutioFileID(rawValue: 442))
    }
    await assertRuntimeError(.invalidResponse) {
      _ = try await runtime.resolveFileDownloadSource(fileID: .root)
    }
  }
}
