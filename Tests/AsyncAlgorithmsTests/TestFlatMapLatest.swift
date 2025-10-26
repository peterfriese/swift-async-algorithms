//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Async Algorithms open source project
//
// Copyright (c) 2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

import XCTest
import AsyncAlgorithms
import AsyncSequenceValidation

final class TestFlatMapLatest: XCTestCase {
  func test_basic() throws {
    guard #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) else {
      throw XCTSkip("Skipped due to Clock/Instant/Duration availability")
    }
    validate { diagram in
      "a---|"
      "1-2-3-|"
      
      diagram.inputs[0].flatMapLatest { _ in diagram.inputs[1] }
      
      "1-2-3-|"
    }
  }

  func test_switching() throws {
    guard #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) else {
      throw XCTSkip("Skipped due to Clock/Instant/Duration availability")
    }
    validate { diagram in
      " -A---B--|"
      "1-2-3-|"
      "--4-5-6-|"
      
      diagram.inputs[0].flatMapLatest { element in
        if element == "A" {
          return diagram.inputs[1]
        } else {
          return diagram.inputs[2]
        }
      }
      
      " --1-2---4-5-6-|"
    }
  }

  func test_completion() throws {
    guard #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) else {
      throw XCTSkip("Skipped due to Clock/Instant/Duration availability")
    }
    validate { diagram in
      "a-|"
      "--1-2-|"
      
      diagram.inputs[0].flatMapLatest { _ in diagram.inputs[1] }
      
      "--1-2-|"
    }
  }

  func test_inner_failure() throws {
    guard #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) else {
      throw XCTSkip("Skipped due to Clock/Instant/Duration availability")
    }
    validate { diagram in
      "a-----|"
      "-1-^"
      
      diagram.inputs[0].flatMapLatest { _ in diagram.inputs[1] }
      
      "-1-^"
    }
  }

  func test_outer_failure() throws {
    guard #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) else {
      throw XCTSkip("Skipped due to Clock/Instant/Duration availability")
    }
    validate { diagram in
      "a-^"
      "-1-2-3-4-|"
      
      diagram.inputs[0].flatMapLatest { _ in diagram.inputs[1] }
      
      "-^"
    }
  }

  func test_empty_outer_sequence() throws {
    guard #available(macOS 13.0, iOS 16.0, watchOS 9.0, tvOS 16.0, *) else {
      throw XCTSkip("Skipped due to Clock/Instant/Duration availability")
    }
    validate { diagram in
      "|"
      
      diagram.inputs[0].flatMapLatest { _ in diagram.inputs[0] }
      
      "|"
    }
  }

  private final class DeinitSequence<Element>: AsyncSequence, Sendable {
    typealias AsyncIterator = Iterator
    let expectation: XCTestExpectation
    
    init(expectation: XCTestExpectation) {
      self.expectation = expectation
    }
    
    func makeAsyncIterator() -> Iterator {
      Iterator(expectation: expectation)
    }
    
    final class Iterator: AsyncIteratorProtocol, Sendable {
      let expectation: XCTestExpectation
      
      init(expectation: XCTestExpectation) {
        self.expectation = expectation
      }
      
      deinit {
        expectation.fulfill()
      }
      
      func next() async -> Element? {
        // We never return a value, just hang until cancelled.
        try? await Task.sleep(nanoseconds: 1_000_000_000_000)
        return nil
      }
    }
  }

  func test_cancellation() async throws {
    let expectation = expectation(description: "Inner sequence iterator should be deinitialized")
    let outer = AsyncChannel<Int>()
    let sequence = outer.flatMapLatest { _ in
      DeinitSequence<String>(expectation: expectation)
    }
    
    let task = Task {
      for try await _ in sequence { }
    }
    
    await outer.send(1)
    // A brief sleep to ensure the inner task has started.
    try await Task.sleep(nanoseconds: 100_000_000)
    
    task.cancel()
    
    await fulfillment(of: [expectation], timeout: 1)
  }
}