//
//  Countdown.swift
//  AltWidgetExtension
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import SwiftUI
import WidgetKit

struct Countdown: View
{
    var startDate: Date?
    var endDate: Date?
    var currentDate: Date = Date()
    
    var strokeWidth: Double = 4.0
    
    @Environment(\.font) private var font
    
    // Chuỗi hiển thị Ngày - Giờ
    private var remainingTimeText: String {
        guard let endDate = self.endDate else { return "0d 0h" }
        
        // Nếu đã quá hạn
        if endDate <= self.currentDate {
            return "0d 0h" // Bạn có thể đổi thành "0n 0g" hoặc "Hết hạn"
        }
        
        let remaining = endDate.remainingDaysAndHours(since: self.currentDate)
        
        // Đổi chữ "d" (days) và "h" (hours) thành "n" và "g" nếu muốn tiếng Việt
        return "\(remaining.days)d \(remaining.hours)h"
    }
    
    // Tính thanh tiến trình chính xác theo từng giây (thay vì theo ngày như cũ)
    private var fractionComplete: CGFloat {
        guard let startDate = self.startDate, let endDate = self.endDate else { return 1.0 }
        
        let totalTime = endDate.timeIntervalSince(startDate)
        let remainingTime = endDate.timeIntervalSince(self.currentDate)
        
        guard totalTime > 0 else { return 0.0 }
        
        let fraction = CGFloat(remainingTime / totalTime)
        return min(max(fraction, 0.0), 1.0) // Giới hạn từ 0.0 đến 1.0
    }
        
    @ViewBuilder
    private func overlay(progress: CGFloat) -> some View
    {
        let strokeStyle = StrokeStyle(lineWidth: self.strokeWidth, lineCap: .round, lineJoin: .round)
        
        // Luôn dùng hình viên thuốc (Capsule) vì chữ "6d 14h" dài hơn 1 con số, để hình tròn sẽ bị tràn viền
        Capsule(style: .continuous)
            .trim(from: 0.0, to: progress)
            .stroke(style: strokeStyle)
    }
    
    var body: some View {
        Text(remainingTimeText)
            .font((font ?? .title3).monospacedDigit()) // Dùng .title3 để chữ vừa vặn hơn
            .bold()
            .lineLimit(1)
            .minimumScaleFactor(0.5) // Tự động thu nhỏ chữ nếu không đủ chỗ
            .opacity(endDate != nil ? 1 : 0)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(
                ZStack {
                    overlay(progress: 1.0)
                        .opacity(0.3)
                    
                    overlay(progress: fractionComplete)
                }
            )
    }
}

struct Countdown_Previews: PreviewProvider {
    static var previews: some View {
        let startDate = Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date()
        Group {
            Countdown(startDate: startDate, endDate: Calendar.current.date(byAdding: .hour, value: 160, to: startDate))
            Countdown(startDate: startDate, endDate: Calendar.current.date(byAdding: .day, value: 365, to: startDate))
        }
        .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}
