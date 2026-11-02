
//
//  Date+Widget.swift
//  AltWidget
//
//  Created by Magesh K on 8/13/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation

extension Date {
    func numberOfCalendarDays(since date: Date) -> Int {
        let calendar = Calendar.current
        let startOfSelf = calendar.startOfDay(for: self)
        let startOfOther = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.day], from: startOfOther, to: startOfSelf)
        return components.day ?? 0
    }
    
    // Hàm mới: Tính chính xác số Ngày và Giờ còn lại
    func remainingDaysAndHours(since date: Date) -> (days: Int, hours: Int) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day, .hour], from: date, to: self)
        let days = max(components.day ?? 0, 0)
        let hours = max(components.hour ?? 0, 0)
        return (days, hours)
    }
}
