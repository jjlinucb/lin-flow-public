//! Naming a meeting note after the call it records, from the call app's window titles.
//!
//! John, 2026-11-10: a Teams call titled "Software CCB" saved as "Meeting Nov 10, 10:02 AM", so
//! the list was a column of dates. Teams titles its call window with the meeting's name and its
//! main window with the section it shows ("Calendar", "Chat"), and Lin Flow reads other apps'
//! window titles through the Accessibility grant the talk key already holds. (CGWindowList would
//! need Screen Recording, which the system audio tap does not.) Zoom titles its call window
//! "Zoom Meeting" whatever the topic (its own strings say so), so a Zoom note keeps its date name.
//! This half has no OS calls: the platform hands over titles, and this says what to call the note.

use super::detect::CALL_APPS;

/// The ids whose windows carry a call app's meeting name, by the name `detect` gives the app.
/// The microphone is often held by a helper (Teams' modulehost) while the windows belong to the
/// app itself, so these are the apps, not the microphone users.
pub fn window_owners(app_name: &str) -> &'static [&'static str] {
    match app_name {
        "Teams" => &["com.microsoft.teams2", "com.microsoft.teams"],
        _ => &[],
    }
}

/// The meeting's name from the call app's window titles, front window first, or None when no
/// window names one.
pub fn call_title(app_name: &str, window_titles: &[String]) -> Option<String> {
    match app_name {
        "Teams" => window_titles.iter().find_map(|t| teams_title(t)),
        _ => None,
    }
}

/// Teams' sections, which title the main window instead of a meeting.
const TEAMS_SECTIONS: &[&str] = &[
    "activity", "chat", "teams", "calendar", "calls", "files", "onedrive", "apps", "copilot", "meet", "communities", "assignments",
    "approvals", "shifts", "planner", "tasks", "bookings", "lists", "people", "help", "settings", "search", "notifications",
    "viva engage", "viva insights", "updates", "wiki",
];

/// Parts of a Teams title that name the app or a kind of window, never a meeting.
const TEAMS_GENERIC: &[&str] = &[
    "microsoft teams",
    "microsoft teams (work or school)",
    "microsoft teams classic",
    "microsoft teams notification",
    "notification",
    "meeting",
    "meeting compact view",
    "compact view",
    "meeting chat",
    "call",
    "screen sharing toolbar",
    "sharing control bar",
    "loading",
];

fn teams_title(title: &str) -> Option<String> {
    let mut parts: Vec<&str> = title.split('|').map(str::trim).filter(|p| !p.is_empty()).collect();
    if let Some(first) = parts.first_mut() {
        *first = without_count(first);
    }
    if TEAMS_SECTIONS.contains(&parts.first()?.to_lowercase().as_str()) {
        return None;
    }
    let name = parts.into_iter().find(|p| !p.contains('@') && !TEAMS_GENERIC.contains(&p.to_lowercase().as_str()))?;
    (crate::text::unicode::count(name) <= 200).then(|| name.to_string())
}

/// "(3) Software CCB" is "Software CCB" with three unread messages.
fn without_count(part: &str) -> &str {
    if let Some(rest) = part.strip_prefix('(') {
        if let Some((n, after)) = rest.split_once(')') {
            if !n.is_empty() && n.chars().all(|c| c.is_ascii_digit()) {
                return after.trim_start();
            }
        }
    }
    part
}

/// A title Lin Flow made up from the date ("Meeting Nov 10, 10:02 AM", or "Teams Meeting ..."
/// when started from an offer), which a call's name may replace. Anything else John typed.
pub fn is_automatic(title: &str) -> bool {
    let rest = CALL_APPS.iter().find_map(|(_, name)| title.strip_prefix(name).and_then(|r| r.strip_prefix(' '))).unwrap_or(title);
    let Some(when) = rest.strip_prefix("Meeting ") else { return false };
    chrono::NaiveDateTime::parse_from_str(&format!("2000 {when}"), "%Y %b %d, %I:%M %p").is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::notes::MeetingNote;
    use chrono::TimeZone;

    fn titles(t: &[&str]) -> Vec<String> {
        t.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn a_teams_call_is_named_after_its_window() {
        // The shapes seen on 2026-11-10: the call window carries the name alone, the main window
        // the section it shows.
        assert_eq!(call_title("Teams", &titles(&["Budget Review", "Calendar"])), Some("Budget Review".into()));
        assert_eq!(call_title("Teams", &titles(&["Calendar", "Budget Review"])), Some("Budget Review".into()), "the main window is passed over");
        // Suffixes, accounts and unread counts other Teams versions add.
        assert_eq!(call_title("Teams", &titles(&["Budget Review | Microsoft Teams"])), Some("Budget Review".into()));
        assert_eq!(call_title("Teams", &titles(&["Budget Review | Contoso | pat@contoso.com | Microsoft Teams"])), Some("Budget Review".into()));
        assert_eq!(call_title("Teams", &titles(&["(2) Budget Review | Microsoft Teams (work or school)"])), Some("Budget Review".into()));
        assert_eq!(call_title("Teams", &titles(&["Meeting compact view | Budget Review | Microsoft Teams"])), Some("Budget Review".into()));
        assert_eq!(call_title("Teams", &titles(&["Weekly 1:1 (Q4) | Microsoft Teams"])), Some("Weekly 1:1 (Q4)".into()), "a name's own brackets stay");
    }

    #[test]
    fn no_meeting_window_means_no_name() {
        for set in [
            vec![],
            vec!["Calendar"],
            vec!["Chat | Pat Lee | Microsoft Teams", "Microsoft Teams"],
            vec!["(4) Activity | Microsoft Teams"],
            vec!["Microsoft Teams Notification", "Sharing control bar", ""],
            vec![" | pat@contoso.com | Microsoft Teams"],
        ] {
            assert_eq!(call_title("Teams", &titles(&set)), None, "{set:?}");
        }
        assert_eq!(call_title("Teams", &titles(&[&"x".repeat(201)])), None, "not a page of text");
    }

    #[test]
    fn zoom_and_others_keep_the_date() {
        assert_eq!(call_title("Zoom", &titles(&["Zoom Meeting", "Zoom Workplace", "Participants (6)"])), None);
        assert_eq!(call_title("Chrome", &titles(&["Meet - abc-defg-hij"])), None);
        assert!(window_owners("Zoom").is_empty() && window_owners("Teams").contains(&"com.microsoft.teams2"));
    }

    #[test]
    fn made_up_titles_are_known_from_typed_ones() {
        for (h, m) in [(0, 0), (9, 5), (10, 2), (12, 30), (23, 59)] {
            let at = chrono::Local.with_ymd_and_hms(2026, 11, 3, h, m, 0).unwrap();
            let title = MeetingNote::default_title(at);
            assert!(is_automatic(&title), "{title}");
            assert!(is_automatic(&format!("Teams {title}")), "Teams {title}");
            assert!(is_automatic(&format!("Zoom {title}")), "Zoom {title}");
        }
        assert!(is_automatic("Meeting Feb 29, 7:00 AM"));
        for typed in ["Software CCB", "Meeting with Pat", "Meeting Nov 10", "Meeting Nov 10, 10:02 AM notes", "Lunch Meeting Nov 10, 10:02 AM", "", "Zoom Meeting"] {
            assert!(!is_automatic(typed), "{typed}");
        }
    }
}
