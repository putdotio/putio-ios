import Foundation
import Testing

@testable import PutioHarnessKit

@Test func cleansOnlyRegisteredSimulatorIdentifiers() throws {
  let registry = OwnedSimulatorRegistry()
  registry.register("owned-b")
  registry.register("owned-a")
  var cleaned: [String] = []

  try registry.cleanup(["owned-b", "unowned", "owned-a"]) { identifiers in
    cleaned = identifiers
  }

  #expect(cleaned == ["owned-a", "owned-b"])
  #expect(registry.ownedIdentifiers.isEmpty)
}

@Test func retainsOwnershipWhenCleanupFails() {
  let registry = OwnedSimulatorRegistry()
  registry.register("owned-a")

  #expect(throws: HarnessFailure.self) {
    try registry.cleanupAll { _ in
      throw HarnessFailure("injected cleanup failure")
    }
  }
  #expect(registry.ownedIdentifiers == ["owned-a"])
}

@Test func registersCreatedIdentifierBeforeReturning() throws {
  let registry = OwnedSimulatorRegistry()

  let identifier = try registry.registerCreated(
    name: "created-a",
    snapshot: { [] },
    create: { "created-a" },
    reconcile: {
      Issue.record("successful creation should not reconcile")
      return []
    }
  )

  #expect(identifier == "created-a")
  #expect(registry.ownedIdentifiers == ["created-a"])
}

@Test func failedCreationDoesNotClaimOwnership() {
  let registry = OwnedSimulatorRegistry()

  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "created-a",
      snapshot: { [] },
      create: { throw HarnessFailure("injected creation failure") },
      reconcile: { [] }
    )
  }
  #expect(registry.ownedIdentifiers.isEmpty)
  #expect(registry.pendingCreationCount == 1)
}

@Test func reconcilesCreatedIdentifierWhenCreationReportsFailure() {
  let registry = OwnedSimulatorRegistry()

  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "created-a",
      snapshot: { ["preexisting"] },
      create: { throw HarnessFailure("injected post-creation failure") },
      reconcile: { ["preexisting", "created-a"] }
    )
  }
  #expect(registry.ownedIdentifiers == ["created-a"])
}

@Test func preservesValidatedIdentifierReturnedByFailedCreation() {
  let registry = OwnedSimulatorRegistry()
  var reconciled = false

  #expect(throws: SimulatorCreationFailure.self) {
    try registry.registerCreated(
      name: "created-a",
      snapshot: { [] },
      create: {
        throw SimulatorCreationFailure(
          identifier: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
          failure: HarnessFailure("injected failed create")
        )
      },
      reconcile: {
        reconciled = true
        return []
      }
    )
  }
  #expect(reconciled)
  #expect(registry.ownedIdentifiers == ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"])
  #expect(registry.pendingCreationCount == 1)
}

@Test func validatesSimulatorIdentifiersFromProcessOutput() {
  #expect(
    validatedSimulatorIdentifier("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa\n")
      == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
  #expect(validatedSimulatorIdentifier("create failed") == nil)
}

@Test func retriesPendingReconciliationDuringTeardown() throws {
  let registry = OwnedSimulatorRegistry()

  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "created-a",
      snapshot: { ["preexisting"] },
      create: { throw HarnessFailure("injected post-creation failure") },
      reconcile: { throw HarnessFailure("injected reconciliation failure") }
    )
  }
  #expect(registry.pendingCreationCount == 1)

  try registry.reconcilePending { name in
    #expect(name == "created-a")
    return ["preexisting", "created-a"]
  }
  #expect(registry.pendingCreationCount == 0)
  #expect(registry.ownedIdentifiers == ["created-a"])
}

@Test func terminalReconciliationChildIgnoresRepeatedSignals() throws {
  let registry = OwnedSimulatorRegistry()
  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "created-a",
      snapshot: { [] },
      create: { throw HarnessFailure("injected post-creation failure") },
      reconcile: { throw HarnessFailure("defer reconciliation until teardown") }
    )
  }
  var cleaned: [String] = []

  try registry.terminateAndCleanup(
    reconcile: { _ in
      let output = try ProcessRunner().runIgnoringTerminationSignals(
        "/bin/sh",
        ["-c", "kill -TERM $$; kill -INT $$; printf created-a"]
      )
      #expect(output.status == 0)
      return [output.stdout]
    },
    cleanup: { cleaned = $0 }
  )

  #expect(cleaned == ["created-a"])
}

@Test func emptyImmediateReconciliationRemainsPendingUntilTeardown() throws {
  let registry = OwnedSimulatorRegistry()

  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "created-a",
      snapshot: { ["preexisting"] },
      create: { throw HarnessFailure("injected post-creation failure") },
      reconcile: { ["preexisting"] }
    )
  }
  #expect(registry.pendingCreationCount == 1)
  #expect(registry.ownedIdentifiers.isEmpty)

  var cleaned: [String] = []
  try registry.terminateAndCleanup(
    reconcile: { name in
      #expect(name == "created-a")
      return ["preexisting", "created-a"]
    },
    cleanup: { cleaned = $0 }
  )

  #expect(cleaned == ["created-a"])
  #expect(registry.pendingCreationCount == 0)
  #expect(registry.ownedIdentifiers.isEmpty)
}

@Test func repeatedRunIdentifiersProduceDistinctFullSuffixes() throws {
  let runID = "same-run-prefix-with-a-distinguishing-tail"
  let firstAttempt = try #require(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
  let secondAttempt = try #require(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))

  let first = simulatorSessionSuffix(runID: runID, attemptID: firstAttempt)
  let second = simulatorSessionSuffix(runID: runID, attemptID: secondAttempt)

  #expect(first != second)
  #expect(first == "\(runID)-aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
  #expect(second == "\(runID)-bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
}

@Test func cleanupFailureDoesNotReplaceSuccessfulPrimaryResult() throws {
  var reportedError: Error?

  let value = try preservingPrimaryResult(
    .success("primary-success"),
    cleanup: { throw HarnessFailure("injected cleanup failure") },
    reportCleanupFailure: { reportedError = $0 }
  )

  #expect(value == "primary-success")
  #expect(reportedError is HarnessFailure)
}

@Test func terminalCleanupRejectsLaterCreation() throws {
  let registry = OwnedSimulatorRegistry()
  try registry.cleanupAll { _ in }

  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "late-device",
      snapshot: { [] },
      create: { "late-device-id" },
      reconcile: { [] }
    )
  }
  #expect(registry.ownedIdentifiers.isEmpty)
}

@Test func reconciliationFailureStillCleansKnownIdentifiers() {
  let registry = OwnedSimulatorRegistry()
  registry.register("known-device")
  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "pending-device",
      snapshot: { [] },
      create: { throw HarnessFailure("injected post-creation failure") },
      reconcile: { throw HarnessFailure("injected immediate reconciliation failure") }
    )
  }
  var cleaned: [String] = []

  #expect(throws: HarnessFailure.self) {
    try registry.terminateAndCleanup(
      reconcile: { _ in throw HarnessFailure("injected teardown reconciliation failure") },
      cleanup: { cleaned = $0 }
    )
  }
  #expect(cleaned == ["known-device"])
  #expect(registry.ownedIdentifiers.isEmpty)
}

@Test func reconciliationFailureDoesNotSkipLaterPendingDevices() {
  let registry = OwnedSimulatorRegistry()
  for name in ["pending-first", "pending-second"] {
    #expect(throws: HarnessFailure.self) {
      try registry.registerCreated(
        name: name,
        snapshot: { [] },
        create: { throw HarnessFailure("injected post-creation failure") },
        reconcile: { throw HarnessFailure("defer reconciliation until teardown") }
      )
    }
  }
  var cleaned: [String] = []

  #expect(throws: HarnessFailure.self) {
    try registry.terminateAndCleanup(
      reconcile: { name in
        if name == "pending-first" {
          throw HarnessFailure("injected first reconciliation failure")
        }
        return ["owned-second"]
      },
      cleanup: { cleaned = $0 }
    )
  }

  #expect(cleaned == ["owned-second"])
  #expect(registry.pendingCreationCount == 1)
  #expect(registry.ownedIdentifiers.isEmpty)
}

@Test func emptyTerminalReconciliationRemainsUnresolved() {
  let registry = OwnedSimulatorRegistry()
  #expect(throws: HarnessFailure.self) {
    try registry.registerCreated(
      name: "pending-device",
      snapshot: { [] },
      create: { throw HarnessFailure("injected post-creation failure") },
      reconcile: { [] }
    )
  }

  #expect(throws: HarnessFailure.self) {
    try registry.terminateAndCleanup(
      reconcile: { _ in [] },
      cleanup: { _ in Issue.record("nothing is known to clean") }
    )
  }

  #expect(registry.pendingCreationCount == 1)
  #expect(registry.ownedIdentifiers.isEmpty)
}
