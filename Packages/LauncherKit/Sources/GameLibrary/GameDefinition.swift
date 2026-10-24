// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import LauncherCore

// Keep source compatibility for clients that import GameLibrary. Shared metadata
// lives below delivery/art/launch so those modules use the same edition registry.
public typealias GameDefinition = LauncherCore.GameDefinition
public typealias GameFamily = LauncherCore.GameFamily
public typealias VoiceOption = LauncherCore.VoiceOption
