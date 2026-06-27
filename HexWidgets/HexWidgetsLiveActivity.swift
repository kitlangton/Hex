//
//  HexWidgetsLiveActivity.swift
//  HexWidgets
//
//  Created by Conglei Shi on 6/26/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct HexWidgetsAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct HexWidgetsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HexWidgetsAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension HexWidgetsAttributes {
    fileprivate static var preview: HexWidgetsAttributes {
        HexWidgetsAttributes(name: "World")
    }
}

extension HexWidgetsAttributes.ContentState {
    fileprivate static var smiley: HexWidgetsAttributes.ContentState {
        HexWidgetsAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: HexWidgetsAttributes.ContentState {
         HexWidgetsAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: HexWidgetsAttributes.preview) {
   HexWidgetsLiveActivity()
} contentStates: {
    HexWidgetsAttributes.ContentState.smiley
    HexWidgetsAttributes.ContentState.starEyes
}
