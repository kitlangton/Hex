//
//  KeyEvent.swift
//  HexCore
//
//  Created by Kit Langton on 1/28/25.
//

import Sauce

public enum InputEvent {
    case keyboard(KeyEvent)
    case mouseClick
}

public struct KeyEvent {
    public let key: Key?
    public let modifiers: Modifiers
    
    public init(key: Key?, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
