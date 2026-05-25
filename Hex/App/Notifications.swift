import Foundation

extension NSNotification.Name {
  /// Posted when app mode settings change (dock icon visibility, etc.)
  static let updateAppMode = NSNotification.Name("UpdateAppMode")

  /// Posted when CoachFeature wants the popover to come forward (e.g. analysis started).
  static let coachShouldPresentPopover = NSNotification.Name("CoachShouldPresentPopover")
}
