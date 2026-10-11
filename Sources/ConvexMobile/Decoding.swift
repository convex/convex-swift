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
