public enum FailureStage: String, Codable, Sendable {
    case download, verify, stage, commit, cleanup, runtimeInstall, gptkImport, prefixCreation, launch
}

