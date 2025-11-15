import Dependencies
import IOKit.pwr_mgt

extension SleepManagementClient: DependencyKey {
  public static var liveValue: Self {
    let live = SleepManagementClientLive()
    return Self(
      preventSleep: { reason in
        await live.preventSleep(reason: reason)
      },
      allowSleep: {
        await live.allowSleep()
      }
    )
  }
}

/// Live implementation of SleepManagementClient that manages assertion lifecycle.
actor SleepManagementClientLive {
  private var currentAssertionID: IOPMAssertionID?

  func preventSleep(reason: String) {
    // Release any existing assertion first
    if let existingID = currentAssertionID {
      IOPMAssertionRelease(existingID)
      currentAssertionID = nil
    }

    // Create new assertion
    let reasonForActivity = reason as CFString
    var assertionID: IOPMAssertionID = 0
    let success = IOPMAssertionCreateWithName(
      kIOPMAssertionTypeNoDisplaySleep as CFString,
      IOPMAssertionLevel(kIOPMAssertionLevelOn),
      reasonForActivity,
      &assertionID
    )

    if success == kIOReturnSuccess {
      currentAssertionID = assertionID
    }
  }

  func allowSleep() {
    if let assertionID = currentAssertionID {
      IOPMAssertionRelease(assertionID)
      currentAssertionID = nil
    }
  }
}
