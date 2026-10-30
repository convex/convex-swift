//
//  Encoding.swift
//  ConvexMobile
//
//  Created by Christian Wyglendowski on 10/1/24.
//

import Foundation

public protocol ConvexEncodable {
  func convexEncode() throws -> String
}

extension ConvexEncodable where Self: FixedWidthInteger, Self: Encodable {
  public func convexEncode() throws -> String {
    let data = withUnsafeBytes(of: Int64(self)) { Data($0) }
    return String(
      decoding: try JSONEncoder().encode(["$integer": data.base64EncodedString()]), as: UTF8.self)
  }
}

extension ConvexEncodable where Self: BinaryFloatingPoint, Self: Encodable {
  public func convexEncode() throws -> String {
    var requiresSpecialEncoding = false
    let asDouble = Double(self)
    if asDouble.isNaN || asDouble == Double.infinity || asDouble == -Double.infinity {
      requiresSpecialEncoding = true
    }
    if requiresSpecialEncoding {
      let data = withUnsafeBytes(of: Float64(self)) { Data($0) }
      return String(
        decoding: try JSONEncoder().encode(["$float": data.base64EncodedString()]), as: UTF8.self)
    }
    return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }
}

extension ConvexEncodable where Self: Encodable {
  public func convexEncode() throws -> String {
    return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
  }
}

extension Int: ConvexEncodable {}
extension Int32: ConvexEncodable {}
extension Int64: ConvexEncodable {}
extension Float: ConvexEncodable {}
extension Double: ConvexEncodable {}
extension Bool: ConvexEncodable {}
extension String: ConvexEncodable {}
extension Optional: ConvexEncodable where Wrapped: ConvexEncodable {
    public func convexEncode() throws -> String {
        switch self {
        case .none:
            "null"
        case .some(let wrapped):
            try wrapped.convexEncode()
        }
    }
}
extension Dictionary: ConvexEncodable where Key == String, Value == ConvexEncodable {
  public func convexEncode() throws -> String {
    var kvPairs: [String] = []
    for key in self.keys {
      let value = self[key]
      let encodedValue = try value?.convexEncode()
      kvPairs.append("\"\(key)\":\(encodedValue)")
    }
    return "{\(kvPairs.joined(separator: ","))}"
  }
}
extension Array: ConvexEncodable where Element: ConvexEncodable {
    public func convexEncode() throws -> String {
        var encodedValues: [String] = []
        for value in self {
            encodedValues.append(try value.convexEncode())
        }
        return "[\(encodedValues.joined(separator: ","))]"
    }
}
