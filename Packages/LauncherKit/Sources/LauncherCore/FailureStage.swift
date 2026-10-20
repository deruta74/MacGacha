// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
public enum FailureStage: String, Codable, Sendable {
    case download, verify, stage, commit, cleanup, runtimeInstall, gptkImport, prefixCreation, launch
}

