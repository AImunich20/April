// Compat.swift — build ด้วย swiftc ของ Command Line Tools (ไม่มี Xcode) ไม่มี plugin ของ macro @State
// -> ใช้ property wrapper ตรงๆ ผ่านชื่อนี้แทน (วิธีเดียวกับ Envy)

import SwiftUI

typealias ViewState = SwiftUI.State
