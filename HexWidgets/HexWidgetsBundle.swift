//
//  HexWidgetsBundle.swift
//  HexWidgets
//
//  Created by Conglei Shi on 6/26/26.
//

import WidgetKit
import SwiftUI

@main
struct HexWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HexWidgets()
        HexWidgetsControl()
        HexWidgetsLiveActivity()
    }
}
