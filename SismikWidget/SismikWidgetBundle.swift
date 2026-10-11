//
//  SismikWidgetBundle.swift
//  SismikWidget
//

import WidgetKit
import SwiftUI

@main
struct SismikWidgetBundle: WidgetBundle {
    var body: some Widget {
        SismikWidget()
        SismikStatsWidget()
        AftershockLiveActivity()
    }
}
