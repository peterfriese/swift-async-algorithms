# flatMapLatest

* Proposal: [NNNN](NNNN-flatMapLatest.md)
* Authors: [Peter Friese](https://github.com/peterfriese)
* Review Manager: TBD
* Status: **Awaiting implementation**

*During the review process, add the following fields as needed:*

* Implementation: TBD
* Decision Notes: TBD
* Bugs: TBD

## Introduction

This proposal introduces the `flatMapLatest` algorithm for `AsyncSequence`. This operator transforms elements from a base asynchronous sequence into new asynchronous sequences (called "inner" sequences) and forwards elements from only the most recently transformed inner sequence. Whenever the base sequence emits a new element, the previously active inner sequence is cancelled, and the operator switches to the new one. This is particularly useful in scenarios where work should be superseded by newer, more relevant work, such as responding to user input in a search field.

Swift forums thread: TBD

## Motivation

In asynchronous programming, a common pattern involves reacting to events from one stream by starting work that itself produces a stream of results. For example, a stream of user authentication states might trigger a stream of database updates for the current user, or a stream of search queries might trigger a stream of network requests for search results.

A challenge arises when the source stream (e.g., auth state, search queries) emits a new value before the work for the previous value has completed. In many cases, the results from the previous work are no longer relevant. Continuing this work is inefficient, and receiving its results can lead to inconsistent or incorrect application state (e.g., showing search results for an old query after results for the new query have already arrived).

Currently, handling this requires manual management of `Task` handles, which is complex and error-prone.

```swift
// Current manual workaround
var currentTask: Task<Void, Never>?
for await user in Auth.auth().authStateChanges {
  currentTask?.cancel() // Manually cancel the previous task
  currentTask = Task {
    do {
      // Create a new listener for the new user
      for try await todos in db.collection("todos").whereField("userId", isEqualTo: user.id).snapshots {
        // update UI...
      }
    } catch {
      // handle error
    }
  }
}
```

This manual approach is cumbersome, hard to get right (especially with error handling and cancellation), and does not compose well with other asynchronous algorithms. The `flatMapLatest` operator provides a declarative, robust, and efficient solution to this common problem.

## Proposed solution

We propose adding a `flatMapLatest` method to `AsyncSequence`. This operator will manage the lifecycle of inner sequences automatically, ensuring that only the latest one is active.

```swift
let authStateChanges = Auth.auth().authStateChanges
let todos = authStateChanges.flatMapLatest { user in
  db.collection("todos")
    .whereField("userId", isEqualTo: user?.uid ?? "")
    .snapshots
    .map { querySnapshot in
      querySnapshot.documents.compactMap { try? $0.data(as: Todo.self) }
    }
}

for try await userTodos in todos {
  // This loop will now automatically receive todos for the latest user,
  // and the previous database listener will be cancelled.
  updateUI(with: userTodos)
}
```

This solution is cleaner, safer, and more efficient. It encapsulates the complex cancellation logic, prevents race conditions, and integrates seamlessly into the existing `AsyncSequence` ecosystem.

## Detailed design

The `flatMapLatest` operator will be exposed as an extension on `AsyncSequence`.

```swift
extension AsyncSequence {
  /// Transforms elements into new asynchronous sequences, emitting elements
  /// from the most recent inner sequence.
  ///
  /// When a new element is emitted by this sequence (the "outer" sequence), 
  /// the `transform` is called to produce a new "inner" sequence. Iteration on the
  /// previous inner sequence is cancelled, and iteration begins on the new one.
  ///
  /// - Parameter transform: A closure that takes an element of this sequence and
  ///   returns a new asynchronous sequence.
  /// - Returns: An asynchronous sequence that emits elements from the latest
  ///   inner sequence.
  public func flatMapLatest<T: AsyncSequence>(
    _ transform: @Sendable @escaping (Element) async -> T
  ) -> AsyncFlatMapLatestSequence<Self, T>
}

public struct AsyncFlatMapLatestSequence<Base: AsyncSequence, T: AsyncSequence>: AsyncSequence {
  public typealias Element = T.Element
  public typealias Failure = Error

  public struct Iterator: AsyncIteratorProtocol {
    public mutating func next() async throws -> Element?
  }

  public func makeAsyncIterator() -> Iterator
}

extension AsyncFlatMapLatestSequence: Sendable where Base: Sendable, T: Sendable, Base.Element: Sendable { }
```

**Behavioral Semantics:**

1.  **Iteration:** When `next()` is called on the `AsyncFlatMapLatestSequence`'s iterator, it awaits the next element from the base ("outer") sequence.
2.  **Transformation:** Upon receiving an element, it applies the `transform` closure to produce an "inner" `AsyncSequence`.
3.  **Cancellation:** Any currently running inner sequence iteration is immediately cancelled.
4.  **New Iteration:** A new task is started to iterate over the new inner sequence. Elements from this inner sequence are yielded to the consumer of `AsyncFlatMapLatestSequence`.
5.  **Termination:**
    *   If the **outer** sequence finishes, the `flatMapLatest` sequence will wait for the **last inner** sequence to finish, and then it will finish.
    *   If any **inner** sequence throws an error, the `flatMapLatest` sequence will immediately throw that error and terminate.
    *   If the **outer** sequence throws an error, the `flatMapLatest` sequence will immediately throw that error and terminate, cancelling any active inner sequence.
6.  **Sendable Constraints:** The operator requires `Sendable` conformance on the base sequence, its elements, and the transformed sequence, as the core logic involves managing concurrent tasks. The implementation must carefully manage the state of the underlying iterators, which are not `Sendable`. Specifically, an iterator must only be mutated from within the single `Task` responsible for driving it to ensure data-race safety.

## Effect on API resilience

The proposed `AsyncFlatMapLatestSequence` and its `Iterator` will be public but not `@frozen`. This allows for future evolution of the internal implementation without breaking ABI. The implementation will rely on the public API of Swift Concurrency and will not expose any internal details.

## Alternatives considered

-   **`flatMap` (Concurrent):** A version of `flatMap` that merges the results of all inner sequences concurrently (similar to `merge`). This is a different and also useful operator, but it does not solve the problem of superseding old work with new work. It is often called `flatMapMerge` or just `flatMap` in other frameworks.
-   **`flatMap` (Serial):** A version of `flatMap` that waits for each inner sequence to complete before starting the next one (similar to `concat`). This is also a useful operator for ensuring sequential execution, but it is not suitable for the use cases `flatMapLatest` addresses.

`flatMapLatest` is a distinct and highly useful algorithm that is a standard part of most reactive programming libraries (e.g., `switchToLatest` in Combine, `flatMapLatest` in RxSwift, `switchMap` in RxJS), justifying its inclusion as a first-class operator in this package.

## Acknowledgments

The design is heavily inspired by the `switchToLatest` operator in Apple's Combine framework and similar operators in the wider reactive programming community.
