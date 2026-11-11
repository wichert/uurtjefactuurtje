import LibraryStore

enum RecoveryMessage {
    @MainActor static func text(issue: WorkspaceIssue?, availability: WorkspaceAvailability) -> String {
        // An uncertain publication remains uncertain even if its last rows are still displayed.
        if issue == .uncertainSave {
            return """
                The last change may or may not have been saved. Do not repeat it or assume it is \
                safe to discard. Reopen the library when available, then inspect its entries and \
                timer before deciding what to do next.
                """
        }
        switch availability {
        case .opening:
            return "Opening the library. Please wait; no failed action is being repeated."
        case .closing:
            return "Closing the library after accepted work finishes. Please wait."
        default:
            break
        }
        return issue.map { text(for: $0, availability: availability) }
            ?? unavailableText(for: availability)
    }

    private static func text(
        for issue: WorkspaceIssue,
        availability: WorkspaceAvailability,
    ) -> String {
        switch issue {
        case .busy, .unsafeLibrary, .invalidStorage:
            return storageText(for: issue)
        case .recoveryRequired, .command:
            return actionText(for: issue)
        case .revisionConflict:
            return revisionText(availability: availability)
        case .validation:
            return validationText(availability: availability)
        case .unavailable, .closed:
            return """
                The library is unavailable. When reopening is available, explicitly reopen and \
                inspect its entries and timer before making another change.
                """
        case .other:
            return """
                The action could not be completed. Copy the diagnostic details if you need help. \
                Inspect the library before deciding on another action; no failed action is \
                automatically repeated.
                """
        case .uncertainSave:
            return "The save outcome is unknown. Inspect the library before making another change."
        }
    }

    private static func storageText(for issue: WorkspaceIssue) -> String {
        switch issue {
        case .busy:
            return """
                Another app or process is using this library. Close that library in the other \
                process, then explicitly reopen it here. Do not delete lock files.
                """
        case .unsafeLibrary:
            return """
                The library could not be opened safely. Keep its files intact. Copy the library \
                location and diagnostic details before seeking help or restoring a known-good backup.
                """
        case .invalidStorage:
            return """
                The stored library is damaged or uses an unsupported format. Keep its files \
                intact. Check that you are using a compatible app version; seek help or use a \
                known-good backup before reopening.
                """
        default:
            return ""
        }
    }

    private static func actionText(for issue: WorkspaceIssue) -> String {
        switch issue {
        case .recoveryRequired:
            return """
                Time needs review before this action can continue. Open time review and inspect \
                the timer and any pending intervals. Pending sleep time is unbilled.
                """
        case .command:
            return """
                This action could not be completed. Inspect the affected item and the editor's \
                explanation before deciding on a new action.
                """
        default:
            return ""
        }
    }

    private static func revisionText(availability: WorkspaceAvailability) -> String {
        if availability == .blocked {
            return """
                The library changed, and refreshing its view failed. Retained rows may be stale. \
                Explicitly reopen and inspect its entries and timer when available, then refresh \
                the affected editor before deciding on a new action. The failed action was not \
                automatically repeated.
                """
        }
        return """
            The library changed since this action was prepared. Inspect the confirmed rows and \
            refresh the affected editor before deciding on a new action. The failed action was \
            not automatically repeated.
            """
    }

    private static func validationText(
        availability: WorkspaceAvailability,
    ) -> String {
        if availability == .blocked {
            return """
                The library contains data that could not be accepted. Keep its files intact and \
                copy the diagnostic details before seeking help.
                """
        }
        return """
            Some data could not be accepted. Review the affected fields and the editor's explanation \
            before deciding on a new action.
            """
    }

    private static func unavailableText(for availability: WorkspaceAvailability) -> String {
        switch availability {
        case .closed:
            return "The library is closed. Explicitly reopen it to inspect your work."
        case .blocked:
            return """
                The library is blocked. Copy the diagnostic details, then explicitly reopen and \
                inspect it when the underlying problem is resolved.
                """
        case .reviewRequired:
            return """
                Time needs review. Inspect the timer and any pending intervals; pending sleep time is unbilled.
                """
        case .ready:
            return """
                A previous operation reported an error. This is historical feedback, not a current \
                library failure. Inspect the diagnostic details and affected item before deciding what to do next.
                """
        case .opening, .closing:
            return "Please wait for the library operation to finish."
        }
    }
}
