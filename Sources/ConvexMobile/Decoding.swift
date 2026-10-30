//
//  Decoding.swift
//  ConvexMobile
//
//  Created by Christian Wyglendowski on 10/1/24.
//

import Foundation

@propertyWrapper
public struct ConvexInt<IntegerType: FixedWidthInteger>: Decodable, Equatable {
  public var wrappedValue: IntegerType

  public init(wrappedValue: IntegerType) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: ConvexTypeKey.self)
    let b64int = try container.decode(String.self, forKey: .integer)
    self.wrappedValue = Data(base64Encoded: b64int)!.withUnsafeBytes({
      (rawPtr: UnsafeRawBufferPointer) in
      return rawPtr.loadUnaligned(as: IntegerType.self)
    })
  }

  enum ConvexTypeKey: String, CodingKey {
    case integer = "$integer"
  }
}

@propertyWrapper
public struct OptionalConvexInt<IntegerType: FixedWidthInteger>: Decodable, Equatable {
  public var wrappedValue: IntegerType?

  public init(wrappedValue: IntegerType?) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: ConvexTypeKey.self) {
      let b64int = try container.decode(String.self, forKey: .integer)
      self.wrappedValue = Data(base64Encoded: b64int)!.withUnsafeBytes({
        (rawPtr: UnsafeRawBufferPointer) in
        return rawPtr.loadUnaligned(as: IntegerType.self)
      })
    }
  }

  enum ConvexTypeKey: String, CodingKey {
    case integer = "$integer"
  }
}

@propertyWrapper
public struct ConvexFloat<FloatingPointType: BinaryFloatingPoint & Decodable>: Decodable, Equatable
{
  public var wrappedValue: FloatingPointType

  public init(wrappedValue: FloatingPointType) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: ConvexTypeKey.self) {
      let b64float = try container.decode(String.self, forKey: .float)
      self.wrappedValue = Data(base64Encoded: b64float)!.withUnsafeBytes({
        (rawPtr: UnsafeRawBufferPointer) in
        let decoded = rawPtr.loadUnaligned(as: Double.self)
        return FloatingPointType.self(decoded)
      })
    } else {
      self.wrappedValue = try decoder.singleValueContainer().decode(FloatingPointType.self)
    }
  }

  enum ConvexTypeKey: String, CodingKey {
    case float = "$float"
  }
}

@propertyWrapper
public struct OptionalConvexFloat<FloatingPointType: BinaryFloatingPoint & Decodable>: Decodable,
  Equatable
{
  public var wrappedValue: FloatingPointType?

  public init(wrappedValue: FloatingPointType?) {
    self.wrappedValue = wrappedValue
  }

  public init(from decoder: Decoder) throws {
    if let container = try? decoder.container(keyedBy: ConvexTypeKey.self) {
      let b64float = try container.decode(String.self, forKey: .float)
      self.wrappedValue = Data(base64Encoded: b64float)!.withUnsafeBytes({
        (rawPtr: UnsafeRawBufferPointer) in
        let decoded = rawPtr.loadUnaligned(as: Double.self)
        return FloatingPointType.self(decoded)
      })
    } else {
      if let value = try? decoder.singleValueContainer().decode(FloatingPointType.self) {
        self.wrappedValue = value
      }
    }
  }

  enum ConvexTypeKey: String, CodingKey {
    case float = "$float"
  }
}

// This allows for decoding OptionalConvex[Int|Float] when the associated key isn't present in the payload.
extension KeyedDecodingContainer {
  public func decode<T>(_ type: OptionalConvexInt<T>.Type, forKey key: Self.Key) throws
    -> OptionalConvexInt<T>
  {
    return try decodeIfPresent(type, forKey: key) ?? OptionalConvexInt(wrappedValue: nil)
  }

  public func decode<T>(_ type: OptionalConvexFloat<T>.Type, forKey key: Self.Key) throws
    -> OptionalConvexFloat<T>
  {
    return try decodeIfPresent(type, forKey: key) ?? OptionalConvexFloat(wrappedValue: nil)
  }
}

// Encoding the wrappers lets types that use them be written to the client with
// `OptimisticLocalStore.setQuery`, round tripping through the same Convex encoding used for decoding.

private func encodeConvexInt<IntegerType: FixedWidthInteger>(
  _ value: IntegerType, to encoder: Encoder
) throws {
  var container = encoder.container(keyedBy: ConvexIntCodingKey.self)
  // Reinterpret the bits, like decoding does, rather than trapping for unsigned values above
  // `Int64.max`.
  let data = withUnsafeBytes(of: Int64(truncatingIfNeeded: value)) { Data($0) }
  try container.encode(data.base64EncodedString(), forKey: .integer)
}

private func encodeConvexFloat<FloatingPointType: BinaryFloatingPoint & Encodable>(
  _ value: FloatingPointType, to encoder: Encoder
) throws {
  let asDouble = Double(value)
  if asDouble.isNaN || asDouble.isInfinite {
    var container = encoder.container(keyedBy: ConvexFloatCodingKey.self)
    let data = withUnsafeBytes(of: asDouble) { Data($0) }
    try container.encode(data.base64EncodedString(), forKey: .float)
  } else {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }
}

private enum ConvexIntCodingKey: String, CodingKey {
  case integer = "$integer"
}

private enum ConvexFloatCodingKey: String, CodingKey {
  case float = "$float"
}

extension ConvexInt: Encodable {
  public func encode(to encoder: Encoder) throws {
    try encodeConvexInt(wrappedValue, to: encoder)
  }
}

extension OptionalConvexInt: Encodable {
  public func encode(to encoder: Encoder) throws {
    if let wrappedValue {
      try encodeConvexInt(wrappedValue, to: encoder)
    } else {
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    }
  }
}

extension ConvexFloat: Encodable where FloatingPointType: Encodable {
  public func encode(to encoder: Encoder) throws {
    try encodeConvexFloat(wrappedValue, to: encoder)
  }
}

extension OptionalConvexFloat: Encodable where FloatingPointType: Encodable {
  public func encode(to encoder: Encoder) throws {
    if let wrappedValue {
      try encodeConvexFloat(wrappedValue, to: encoder)
    } else {
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    }
  }
}

// This omits OptionalConvex[Int|Float] keys when the value is nil, mirroring decoding.
extension KeyedEncodingContainer {
  public mutating func encode<T>(_ value: OptionalConvexInt<T>, forKey key: Self.Key) throws {
    if value.wrappedValue != nil {
      try encodeIfPresent(value, forKey: key)
    }
  }

  public mutating func encode<T>(_ value: OptionalConvexFloat<T>, forKey key: Self.Key) throws
  where T: Encodable {
    if value.wrappedValue != nil {
      try encodeIfPresent(value, forKey: key)
    }
  }
}
