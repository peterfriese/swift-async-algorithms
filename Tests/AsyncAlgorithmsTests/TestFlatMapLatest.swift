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

  private actor ResultCollector {
    var results = [String]()
    func append(_ value: String) {
      results.append(value)
    }
  }

  func test_basic_asyncChannels() async throws {
    let outer = AsyncChannel<Int>()
    let inner = AsyncChannel<String>()
    let collector = ResultCollector()

    let sequence = outer.flatMapLatest { _ in inner }

    let task = Task {
      for try await value in sequence {
        await collector.append(value)
      }
    }

    await outer.send(1)
    await inner.send("A")
    await inner.send("B")
    await inner.send("C")
    
    outer.finish()
    inner.finish()

    try await task.value

    let finalResults = await collector.results
    XCTAssertEqual(finalResults, ["A", "B", "C"])
  }

  @available(iOS 16.0, *)
  func test_switching_asyncChannels() async throws {
    let outer = AsyncChannel<Int>()
    let inner1 = AsyncChannel<String>()
    let inner2 = AsyncChannel<String>()
    
    let collector = ResultCollector()

    let sequence = outer.flatMapLatest { value -> AsyncChannel<String> in
      if value == 1 {
        return inner1
      } else {
        return inner2
      }
    }

    let task = Task {
      for try await value in sequence {
        await collector.append(value)
      }
    }

    // Start with the first inner sequence
    await outer.send(1)
    await inner1.send("A")
    await inner1.send("B")
    await Task.yield()

    // Switch to the second inner sequence
    await outer.send(2)
    await inner2.send("C")
    await Task.yield()

    // This value should be ignored. We send it in a detached task
    // because we expect it to hang, and we don't want to block the test.
    let hangingSend = Task {
        await inner1.send("D")
    }
    // Give it a moment to see if it completes (it shouldn't)
    try await Task.sleep(for: .milliseconds(100))
    

    await inner2.send("E")
    await Task.yield()

    // Finish all channels to allow the sequence to terminate
    hangingSend.cancel()
    inner1.finish()
    inner2.finish()
    outer.finish()

    // Wait for the iteration task to complete
    try await task.value

    let finalResults = await collector.results
    XCTAssertEqual(finalResults, ["A", "B", "C", "E"])
  }

  func test_completion_asyncChannels() async throws {
    let outer = AsyncChannel<Int>()
    let inner = AsyncChannel<String>()
    let collector = ResultCollector()

    let sequence = outer.flatMapLatest { _ in inner }

    let task = Task {
      for try await value in sequence {
        await collector.append(value)
      }
    }

    await outer.send(1)
    outer.finish() // Finish outer sequence early

    await inner.send("A")
    await inner.send("B")
    inner.finish()

    try await task.value

    let finalResults = await collector.results
    XCTAssertEqual(finalResults, ["A", "B"])
  }

  func test_inner_failure_asyncChannels() async throws {
    let outer = AsyncChannel<Int>()
    let inner = AsyncThrowingChannel<String, Error>()
    let collector = ResultCollector()
    
    struct TestError: Error {}

    let sequence = outer.flatMapLatest { _ in inner }

    let task = Task {
      do {
        for try await value in sequence {
          await collector.append(value)
        }
        XCTFail("The sequence should have thrown an error.")
      } catch {
        XCTAssert(error is TestError)
      }
    }

    await outer.send(1)
    await inner.send("A")
    inner.fail(TestError())

    await task.value
    
    let finalResults = await collector.results
    XCTAssertEqual(finalResults, ["A"])
  }

  func test_outer_failure_asyncChannels() async throws {
    let outer = AsyncThrowingChannel<Int, Error>()
    let inner = AsyncChannel<String>()
    let collector = ResultCollector()
    
    struct TestError: Error {}

    let sequence = outer.flatMapLatest { _ in inner }

    let task = Task {
      do {
        for try await value in sequence {
          await collector.append(value)
        }
        XCTFail("The sequence should have thrown an error.")
      } catch {
        XCTAssert(error is TestError)
      }
    }

    await outer.send(1)
    await inner.send("A")
    outer.fail(TestError())

    await task.value
    
    let finalResults = await collector.results
    XCTAssertEqual(finalResults, ["A"])
  }
}
