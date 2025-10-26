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

import AsyncAlgorithms
import AsyncSequenceValidation
import XCTest

final class TestFlatMapLatest: XCTestCase {
  func testSwitchToLatest() {
    validate { diagram in
      " -A---B--|"
      "A:1-2-3-|"
      "B:--4-5-6-|"
      
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

  func testCompletion() {
    validate { diagram in
      " -A---B-|"
      "A:1-2-3-|"
      "B:--4-5-6----|"
      
      diagram.inputs[0].flatMapLatest { element in
        if element == "A" {
          return diagram.inputs[1]
        } else {
          return diagram.inputs[2]
        }
      }
      
      " --1-2---4-5-6----|"
    }
  }
}
