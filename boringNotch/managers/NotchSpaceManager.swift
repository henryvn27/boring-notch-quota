//
//  NotchSpaceManager.swift
//  boringNotch
//
//  Created by Alexander on 2024-10-27.
//

import AppKit

class NotchSpaceManager {
    static let shared = NotchSpaceManager()
    let notchSpace: CGSSpace
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    
    private init() {
        notchSpace = CGSSpace(level: 2147483647) // Max level
    }

    /// The private SkyLight space is reserved for the lock screen. Keeping
    /// unlocked windows in it bypasses normal Space/window ordering and can
    /// cover another app's help or toolbar surface.
    func attach(_ window: NSWindow) {
        notchSpace.windows.insert(window)
    }

    func detach(_ window: NSWindow) {
        notchSpace.windows.remove(window)
    }
}
