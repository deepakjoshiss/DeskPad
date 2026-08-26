import AppKit

extension NSScreen {
    /// The display this screen is backed by.
    ///
    /// AppKit still publishes this only as an untyped `deviceDescription` entry;
    /// there is no typed accessor. Optional rather than a force cast because the
    /// entry is not guaranteed - a screen enumerated while its display is being
    /// torn down, which a virtual display makes routine, can come back without it.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey(rawValue: "NSScreenNumber")] as? CGDirectDisplayID
    }
}
