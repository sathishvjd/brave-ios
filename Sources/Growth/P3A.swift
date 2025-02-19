// Copyright 2022 The Brave Authors. All rights reserved.
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import BraveCore
import os.log

/// For adding a sample to an enumerated histogram
public func UmaHistogramEnumeration<E: RawRepresentable & CaseIterable>(
  _ name: String,
  sample: E
) where E.RawValue == Int {
  UmaHistogramExactLinear(name, sample.rawValue, E.allCases.count + 1)
}

/// A bucket that may span a single value or a range of values
///
/// Essentially a type eraser around `RangeExpression`
public struct Bucket {
  var contains: (Int) -> Bool
  public static func equals(_ value: Int) -> Self {
    .init(contains: { value == $0 })
  }
  public static func r(_ value: some RangeExpression<Int>) -> Self {
    .init(contains: { value.contains($0) })
  }
}

extension Bucket: ExpressibleByIntegerLiteral {
  public init(integerLiteral value: IntegerLiteralType) {
    self = .equals(value)
  }
}

/// Adds a sample to a specific bucket. The answer will be the index of the bucket the value falls into.
///
/// Examples:
///   `UmaHistogramRecordValueToBucket("", buckets: [0, .r(1..<10), 10, .r(11...)], value: 0)` would answer 0
///   `UmaHistogramRecordValueToBucket("", buckets: [0, .r(1..<10), 10, .r(11...)], value: 4)` would answer 1
///   `UmaHistogramRecordValueToBucket("", buckets: [0, .r(1..<10), 10, .r(11...)], value: 10)` would answer 2
///   `UmaHistogramRecordValueToBucket("", buckets: [0, .r(1..<10), 10, .r(11...)], value: 21)` would answer 3
public func UmaHistogramRecordValueToBucket(
  _ name: String,
  buckets: [Bucket],
  value: Int
) {
  guard let answer = buckets.firstIndex(where: { $0.contains(value) }) else {
    Logger.module.warning("Value (\(value)) not found in any bucket for histogram \(name)")
    return
  }
  UmaHistogramExactLinear(name, answer, buckets.count + 1)
}
