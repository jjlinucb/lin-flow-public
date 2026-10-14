//! What you hold to talk: one key, a combination, or a mouse button, alone or with keys. One
//! model for both computers; each OS shell turns its own events (a Quartz event tap on the Mac,
//! low-level hooks on Windows) into the neutral `HotkeyEvent` below.
//!
//! Defaults differ by computer, as they do today: Fn on the Mac, Left Ctrl + Left Alt on Windows
//! (John's mouse has a button bound to that chord, 2026-09-23). Fn never reaches a Windows hook,
//! since nearly every laptop handles it in keyboard firmware, and Right Ctrl does not exist on
//! laptops whose Copilot key replaced it (LAPTOP-02, 2026-09-18).
//!
//! Stored as part names joined by "+": "fn", "rightOption", "leftControl+leftOption",
//! "middleMouse", "leftCommand+space". The Mac's names are the canonical ones; the Windows app's
//! names ("LeftCtrl+LeftAlt", "RightAlt", "0x5D") read back too, so either app's setting carries
//! over, and the Windows app already reads the Mac's.

use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    Mac,
    Windows,
}

impl Platform {
    pub fn current() -> Platform {
        if cfg!(target_os = "windows") {
            Platform::Windows
        } else {
            Platform::Mac
        }
    }
}

/// Shift, Control, Alt (Option) and the system key (Command, Windows), each side on its own.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Modifier {
    LeftShift,
    RightShift,
    LeftControl,
    RightControl,
    LeftAlt,
    RightAlt,
    LeftMeta,
    RightMeta,
}

impl Modifier {
    pub const ALL: [Modifier; 8] = [
        Modifier::LeftShift,
        Modifier::RightShift,
        Modifier::LeftControl,
        Modifier::RightControl,
        Modifier::LeftAlt,
        Modifier::RightAlt,
        Modifier::LeftMeta,
        Modifier::RightMeta,
    ];

    /// The stored name: the Mac's.
    pub fn name(self) -> &'static str {
        match self {
            Modifier::LeftShift => "leftShift",
            Modifier::RightShift => "rightShift",
            Modifier::LeftControl => "leftControl",
            Modifier::RightControl => "rightControl",
            Modifier::LeftAlt => "leftOption",
            Modifier::RightAlt => "rightOption",
            Modifier::LeftMeta => "leftCommand",
            Modifier::RightMeta => "rightCommand",
        }
    }

    pub fn label(self, p: Platform) -> &'static str {
        match (self, p) {
            (Modifier::LeftShift, _) => "Left Shift",
            (Modifier::RightShift, _) => "Right Shift",
            (Modifier::LeftControl, Platform::Mac) => "Left Control",
            (Modifier::RightControl, Platform::Mac) => "Right Control",
            (Modifier::LeftControl, Platform::Windows) => "Left Ctrl",
            (Modifier::RightControl, Platform::Windows) => "Right Ctrl",
            (Modifier::LeftAlt, Platform::Mac) => "Left Option",
            (Modifier::RightAlt, Platform::Mac) => "Right Option",
            (Modifier::LeftAlt, Platform::Windows) => "Left Alt",
            (Modifier::RightAlt, Platform::Windows) => "Right Alt",
            (Modifier::LeftMeta, Platform::Mac) => "Left Command",
            (Modifier::RightMeta, Platform::Mac) => "Right Command",
            (Modifier::LeftMeta, Platform::Windows) => "Left Windows",
            (Modifier::RightMeta, Platform::Windows) => "Right Windows",
        }
    }

    /// The Mac's virtual key code for this key.
    pub fn mac_key_code(self) -> u32 {
        match self {
            Modifier::LeftShift => 56,
            Modifier::RightShift => 60,
            Modifier::LeftControl => 59,
            Modifier::RightControl => 62,
            Modifier::LeftAlt => 58,
            Modifier::RightAlt => 61,
            Modifier::LeftMeta => 55,
            Modifier::RightMeta => 54,
        }
    }

    /// The device-dependent bit in a Quartz event's flags. The side-less flags cannot tell which
    /// Control is down, so a chord of Left Control would fire on the right one too.
    pub fn mac_device_mask(self) -> u64 {
        match self {
            Modifier::LeftControl => 0x0001,
            Modifier::LeftShift => 0x0002,
            Modifier::RightShift => 0x0004,
            Modifier::LeftMeta => 0x0008,
            Modifier::RightMeta => 0x0010,
            Modifier::LeftAlt => 0x0020,
            Modifier::RightAlt => 0x0040,
            Modifier::RightControl => 0x2000,
        }
    }

    /// The Windows virtual-key code: the hook reports sided codes, never the generic ones.
    pub fn windows_vk(self) -> u32 {
        match self {
            Modifier::LeftShift => 0xA0,
            Modifier::RightShift => 0xA1,
            Modifier::LeftControl => 0xA2,
            Modifier::RightControl => 0xA3,
            Modifier::LeftAlt => 0xA4,
            Modifier::RightAlt => 0xA5,
            Modifier::LeftMeta => 0x5B,
            Modifier::RightMeta => 0x5C,
        }
    }

    pub fn from_mac_key_code(code: u32) -> Option<Modifier> {
        Modifier::ALL.into_iter().find(|m| m.mac_key_code() == code)
    }

    pub fn from_windows_vk(vk: u32) -> Option<Modifier> {
        Modifier::ALL.into_iter().find(|m| m.windows_vk() == vk)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Part {
    /// Fn (Globe), Mac only.
    Fn,
    Mod(Modifier),
    /// Any other key, by the platform's own code: a Mac virtual key code or a Windows VK.
    Key(u32),
    /// An extra mouse button: 2 middle, 3 back, 4 forward. Left and right are never a talk key.
    Mouse(u8),
}

impl Part {
    pub fn is_modifier(self) -> bool {
        matches!(self, Part::Fn | Part::Mod(_))
    }
}

pub const MAC_FN_KEY_CODE: u32 = 63;
pub const MAC_FN_MASK: u64 = 0x0080_0000; // kCGEventFlagMaskSecondaryFn
pub const MAC_ESCAPE: u32 = 53;
pub const WINDOWS_ESCAPE: u32 = 0x1B;

/// Named keys: (stored name, label, Mac code, Windows VK).
const KEYS: &[(&str, &str, u32, u32)] = &[
    ("space", "Space", 49, 0x20),
    ("return", "Return", 36, 0x0D),
    ("tab", "Tab", 48, 0x09),
    ("escape", "Escape", 53, 0x1B),
    ("delete", "Delete", 51, 0x08),
    ("forwardDelete", "Forward Delete", 117, 0x2E),
    ("leftArrow", "Left Arrow", 123, 0x25),
    ("rightArrow", "Right Arrow", 124, 0x27),
    ("downArrow", "Down Arrow", 125, 0x28),
    ("upArrow", "Up Arrow", 126, 0x26),
    ("home", "Home", 115, 0x24),
    ("end", "End", 119, 0x23),
    ("pageUp", "Page Up", 116, 0x21),
    ("pageDown", "Page Down", 121, 0x22),
    ("capsLock", "Caps Lock", 57, 0x14),
    ("backquote", "`", 50, 0xC0),
    ("minus", "-", 27, 0xBD),
    ("equals", "=", 24, 0xBB),
    ("leftBracket", "[", 33, 0xDB),
    ("rightBracket", "]", 30, 0xDD),
    ("backslash", "\\", 42, 0xDC),
    ("semicolon", ";", 41, 0xBA),
    ("quote", "'", 39, 0xDE),
    ("comma", ",", 43, 0xBC),
    ("period", ".", 47, 0xBE),
    ("slash", "/", 44, 0xBF),
    ("menu", "Menu", u32::MAX, 0x5D),
    ("insert", "Insert", u32::MAX, 0x2D),
    ("printScreen", "Print Screen", u32::MAX, 0x2C),
    ("scrollLock", "Scroll Lock", u32::MAX, 0x91),
    ("pause", "Pause", u32::MAX, 0x13),
];

const MAC_LETTERS: [u32; 26] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6];
const MAC_DIGITS: [u32; 10] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25];
const MAC_F_KEYS: [u32; 20] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90];

/// Every named key for a platform: name -> (code, label).
fn key_table(p: Platform) -> HashMap<String, (u32, String)> {
    let mut t = HashMap::new();
    for (name, label, mac, win) in KEYS {
        let code = if p == Platform::Mac { *mac } else { *win };
        if code != u32::MAX {
            t.insert(name.to_string(), (code, label.to_string()));
        }
    }
    for (i, c) in ('a'..='z').enumerate() {
        let code = if p == Platform::Mac { MAC_LETTERS[i] } else { 'A' as u32 + i as u32 };
        t.insert(c.to_string(), (code, c.to_ascii_uppercase().to_string()));
    }
    for d in 0..10u32 {
        let code = if p == Platform::Mac { MAC_DIGITS[d as usize] } else { 0x30 + d };
        t.insert(format!("d{d}"), (code, d.to_string()));
    }
    for f in 1..=20u32 {
        let code = if p == Platform::Mac { MAC_F_KEYS[f as usize - 1] } else { 0x6F + f };
        t.insert(format!("f{f}"), (code, format!("F{f}")));
    }
    t
}

fn key_name(p: Platform, code: u32) -> Option<String> {
    let t = key_table(p);
    let mut names: Vec<&String> = t.iter().filter(|(_, (c, _))| *c == code).map(|(n, _)| n).collect();
    names.sort();
    names.first().map(|s| s.to_string())
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Hotkey {
    /// In the order they were pressed, without repeats.
    pub parts: Vec<Part>,
}

impl Hotkey {
    pub fn new(parts: Vec<Part>) -> Option<Hotkey> {
        let mut seen: Vec<Part> = Vec::new();
        for p in parts {
            if let Part::Mouse(b) = p {
                if b < 2 {
                    return None;
                }
            }
            if !seen.contains(&p) {
                seen.push(p);
            }
        }
        if seen.is_empty() {
            None
        } else {
            Some(Hotkey { parts: seen })
        }
    }

    pub fn fn_key() -> Hotkey {
        Hotkey { parts: vec![Part::Fn] }
    }

    pub fn default_for(p: Platform) -> Hotkey {
        match p {
            Platform::Mac => Hotkey::fn_key(),
            Platform::Windows => Hotkey { parts: vec![Part::Mod(Modifier::LeftControl), Part::Mod(Modifier::LeftAlt)] },
        }
    }

    /// What the menu and Settings offer without recording.
    pub fn presets(p: Platform) -> Vec<Hotkey> {
        let m = |x| Hotkey { parts: vec![Part::Mod(x)] };
        match p {
            Platform::Mac => vec![Hotkey::fn_key(), m(Modifier::RightAlt), m(Modifier::RightMeta), m(Modifier::RightControl), Hotkey { parts: vec![Part::Mouse(2)] }],
            Platform::Windows => vec![
                Hotkey::default_for(p),
                m(Modifier::RightAlt),
                m(Modifier::RightControl),
                Hotkey { parts: vec![Part::Key(0x5D)] },
                Hotkey { parts: vec![Part::Mouse(2)] },
            ],
        }
    }

    /// A stored value, or the platform's default when it is empty or unreadable.
    pub fn load(raw: &str, p: Platform) -> Hotkey {
        Hotkey::parse(raw, p).unwrap_or_else(|| Hotkey::default_for(p))
    }

    pub fn parse(raw: &str, p: Platform) -> Option<Hotkey> {
        let mut parts = Vec::new();
        for token in raw.split('+').map(str::trim).filter(|t| !t.is_empty()) {
            parts.push(parse_part(token, p)?);
        }
        if p == Platform::Windows && parts.contains(&Part::Fn) {
            return None;
        }
        Hotkey::new(parts)
    }

    pub fn raw_value(&self, p: Platform) -> String {
        self.parts.iter().map(|x| part_name(*x, p)).collect::<Vec<_>>().join("+")
    }

    pub fn label(&self, p: Platform) -> String {
        if self.parts == [Part::Fn] {
            return "Fn (Globe)".into();
        }
        self.parts.iter().map(|x| part_label(*x, p)).collect::<Vec<_>>().join(" + ")
    }

    pub fn uses_keys(&self) -> bool {
        self.parts.iter().any(|p| matches!(p, Part::Key(_)))
    }

    pub fn uses_mouse(&self) -> bool {
        self.parts.iter().any(|p| matches!(p, Part::Mouse(_)))
    }
}

fn part_name(part: Part, p: Platform) -> String {
    match part {
        Part::Fn => "fn".into(),
        Part::Mod(m) => m.name().into(),
        Part::Key(c) => key_name(p, c).unwrap_or_else(|| if p == Platform::Mac { format!("key{c}") } else { format!("0x{c:02X}") }),
        Part::Mouse(2) => "middleMouse".into(),
        Part::Mouse(3) => "mouseBack".into(),
        Part::Mouse(4) => "mouseForward".into(),
        Part::Mouse(b) => format!("mouse{b}"),
    }
}

fn part_label(part: Part, p: Platform) -> String {
    match part {
        Part::Fn => "Fn".into(),
        Part::Mod(m) => m.label(p).into(),
        Part::Key(c) => {
            let t = key_table(p);
            key_name(p, c).and_then(|n| t.get(&n).map(|(_, l)| l.clone())).unwrap_or_else(|| format!("Key {c}"))
        }
        Part::Mouse(2) => "Middle Mouse Button".into(),
        Part::Mouse(3) => "Mouse Back Button".into(),
        Part::Mouse(4) => "Mouse Forward Button".into(),
        Part::Mouse(b) => format!("Mouse Button {}", b + 1),
    }
}

fn parse_part(token: &str, p: Platform) -> Option<Part> {
    let lower = token.replace(' ', "").to_lowercase();
    let modifier = match lower.as_str() {
        "fn" | "globe" => return Some(Part::Fn),
        "leftshift" | "shift" => Some(Modifier::LeftShift),
        "rightshift" => Some(Modifier::RightShift),
        "leftcontrol" | "leftctrl" | "ctrl" | "control" => Some(Modifier::LeftControl),
        "rightcontrol" | "rightctrl" => Some(Modifier::RightControl),
        "leftoption" | "leftalt" | "alt" | "option" => Some(Modifier::LeftAlt),
        "rightoption" | "rightalt" | "altgr" => Some(Modifier::RightAlt),
        "leftcommand" | "leftwin" | "win" | "command" | "cmd" => Some(Modifier::LeftMeta),
        "rightcommand" | "rightwin" => Some(Modifier::RightMeta),
        _ => None,
    };
    if let Some(m) = modifier {
        return Some(Part::Mod(m));
    }
    match lower.as_str() {
        "middlemouse" | "middlebutton" | "mbutton" => return Some(Part::Mouse(2)),
        "mouseback" | "xbutton1" => return Some(Part::Mouse(3)),
        "mouseforward" | "xbutton2" => return Some(Part::Mouse(4)),
        "enter" => return parse_part("return", p),
        "esc" => return parse_part("escape", p),
        "backspace" if p == Platform::Windows => return Some(Part::Key(0x08)),
        "apps" => return parse_part("menu", p),
        _ => {}
    }
    if let Some(rest) = lower.strip_prefix("mouse") {
        if let Ok(b) = rest.parse::<u8>() {
            return (b >= 2).then_some(Part::Mouse(b));
        }
    }
    let table = key_table(p);
    if let Some((code, _)) = table.iter().find(|(n, _)| n.to_lowercase() == lower).map(|(_, v)| v.clone()) {
        return Some(Part::Key(code));
    }
    match p {
        Platform::Mac => {
            let code: u32 = lower.strip_prefix("key")?.parse().ok()?;
            if code >= 128 {
                return None;
            }
            if code == MAC_FN_KEY_CODE {
                return Some(Part::Fn);
            }
            Some(Modifier::from_mac_key_code(code).map(Part::Mod).unwrap_or(Part::Key(code)))
        }
        Platform::Windows => {
            let code = if let Some(hex) = lower.strip_prefix("0x") { u32::from_str_radix(hex, 16).ok()? } else { lower.parse().ok()? };
            match code {
                0x01 | 0x02 => None, // the left and right buttons would take over clicking
                0x04 => Some(Part::Mouse(2)),
                0x05 => Some(Part::Mouse(3)),
                0x06 => Some(Part::Mouse(4)),
                1..=0xFF => Some(Modifier::from_windows_vk(code).map(Part::Mod).unwrap_or(Part::Key(code))),
                _ => None,
            }
        }
    }
}

/// One event the talk key cares about, already taken out of the OS's own event.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HotkeyEvent {
    /// The modifiers held after a change (Fn included on the Mac), and the key that changed.
    Modifiers { down: HashSet<Part>, changed: Option<Part> },
    Key { code: u32, down: bool, repeat: bool },
    Mouse { button: u8, down: bool },
}

impl HotkeyEvent {
    /// A Quartz flagsChanged event: which modifiers its device flags say are down.
    pub fn from_mac_flags(flags: u64, key_code: u32) -> HotkeyEvent {
        let mut down = HashSet::new();
        if flags & MAC_FN_MASK != 0 {
            down.insert(Part::Fn);
        }
        for m in Modifier::ALL {
            if flags & m.mac_device_mask() != 0 {
                down.insert(Part::Mod(m));
            }
        }
        let changed = if key_code == MAC_FN_KEY_CODE { Some(Part::Fn) } else { Modifier::from_mac_key_code(key_code).map(Part::Mod) };
        HotkeyEvent::Modifiers { down, changed }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Signal {
    #[default]
    None,
    Press,
    Release,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Outcome {
    pub signal: Signal,
    /// Keep the event from the app under the pointer or the cursor.
    pub swallow: bool,
    /// Hand a quick click of the talk mouse button back as a real click.
    pub replay_click: bool,
}

/// Below this a press of the talk mouse button is a click, not a dictation: the same length
/// under which the dictation controller drops a take, so a press is one or the other.
pub const REPLAY_WINDOW_SECONDS: f64 = 0.35;

/// Turns events into press and release for one hotkey, and says which to swallow:
/// - Fn's own change, whenever Fn is in the hotkey, so the Globe action does not fire.
/// - Never Shift, Control, Alt or Command/Windows: apps rely on seeing their state.
/// - A key or mouse button of the hotkey that completes the combination or arrives while it is
///   held, and then its release. A middle button held to talk should not open a link, and a
///   letter in a chord should not type.
/// - A mouse button released within the replay window asks for its click back.
#[derive(Clone, Debug)]
pub struct HotkeyMatcher {
    pub hotkey: Hotkey,
    required: HashSet<Part>,
    held: HashSet<Part>,
    swallowed_at: HashMap<Part, f64>,
    pub active: bool,
}

impl HotkeyMatcher {
    pub fn new(hotkey: Hotkey) -> Self {
        let required = hotkey.parts.iter().copied().collect();
        HotkeyMatcher { hotkey, required, held: HashSet::new(), swallowed_at: HashMap::new(), active: false }
    }

    pub fn handle(&mut self, event: &HotkeyEvent, time: f64) -> Outcome {
        match event {
            HotkeyEvent::Modifiers { down, changed } => {
                // Every modifier in the hotkey is read back from the full state, not tracked from
                // the one key that changed, so a missed release cannot leave one stuck down.
                for p in self.required.clone() {
                    if p.is_modifier() {
                        if down.contains(&p) {
                            self.held.insert(p);
                        } else {
                            self.held.remove(&p);
                        }
                    }
                }
                let signal = self.evaluate();
                Outcome { signal, swallow: *changed == Some(Part::Fn) && self.required.contains(&Part::Fn), replay_click: false }
            }
            HotkeyEvent::Key { code, down, repeat } => self.button(Part::Key(*code), *down, *repeat, time),
            HotkeyEvent::Mouse { button, down } => self.button(Part::Mouse(*button), *down, false, time),
        }
    }

    fn button(&mut self, p: Part, down: bool, repeat: bool, time: f64) -> Outcome {
        if !self.required.contains(&p) {
            return Outcome::default();
        }
        let mut out = Outcome::default();
        if down {
            if repeat {
                out.swallow = self.active;
                return out;
            }
            self.held.insert(p);
            out.signal = self.evaluate();
            if self.active {
                out.swallow = true;
                self.swallowed_at.insert(p, time);
            }
        } else {
            self.held.remove(&p);
            out.signal = self.evaluate();
            if let Some(at) = self.swallowed_at.remove(&p) {
                out.swallow = true;
                if matches!(p, Part::Mouse(_)) {
                    out.replay_click = time - at < REPLAY_WINDOW_SECONDS;
                }
            }
        }
        out
    }

    fn evaluate(&mut self) -> Signal {
        let now = self.required.is_subset(&self.held);
        let was = self.active;
        self.active = now;
        match (now, was) {
            (true, false) => Signal::Press,
            (false, true) => Signal::Release,
            _ => Signal::None,
        }
    }
}

/// Settings' Record button: everything pressed, in order, until everything is released again.
/// Escape on its own cancels. A left or right click never reaches it.
#[derive(Clone, Debug, Default)]
pub struct HotkeyRecorder {
    down: HashSet<Part>,
    seen: Vec<Part>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Recorded {
    Pending,
    Done(Hotkey),
    Cancelled,
}

impl HotkeyRecorder {
    pub fn handle(&mut self, event: &HotkeyEvent, escape_code: u32) -> Recorded {
        match event {
            HotkeyEvent::Modifiers { down, .. } => {
                let held_mods: HashSet<Part> = self.down.iter().copied().filter(|p| p.is_modifier()).collect();
                let mut newly: Vec<Part> = down.difference(&held_mods).copied().collect();
                newly.sort();
                for p in newly {
                    self.press(p);
                }
                for p in held_mods.difference(down) {
                    self.down.remove(p);
                }
            }
            HotkeyEvent::Key { code, down, repeat } => {
                if *repeat {
                    return Recorded::Pending;
                }
                if *down {
                    self.press(Part::Key(*code));
                } else {
                    self.down.remove(&Part::Key(*code));
                }
            }
            HotkeyEvent::Mouse { button, down } => {
                if *button < 2 {
                    return Recorded::Pending;
                }
                if *down {
                    self.press(Part::Mouse(*button));
                } else {
                    self.down.remove(&Part::Mouse(*button));
                }
            }
        }
        if !self.down.is_empty() || self.seen.is_empty() {
            return Recorded::Pending;
        }
        if self.seen == [Part::Key(escape_code)] {
            return Recorded::Cancelled;
        }
        Hotkey::new(self.seen.clone()).map(Recorded::Done).unwrap_or(Recorded::Cancelled)
    }

    fn press(&mut self, p: Part) {
        self.down.insert(p);
        if !self.seen.contains(&p) {
            self.seen.push(p);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mods(parts: &[Part], changed: Option<Part>) -> HotkeyEvent {
        HotkeyEvent::Modifiers { down: parts.iter().copied().collect(), changed }
    }

    #[test]
    fn storage_round_trips_and_reads_the_windows_names() {
        let mac = Platform::Mac;
        for raw in ["fn", "rightOption", "leftControl+leftOption", "middleMouse", "leftCommand+space", "key50"] {
            let h = Hotkey::parse(raw, mac).unwrap();
            assert_eq!(Hotkey::parse(&h.raw_value(mac), mac), Some(h), "{raw}");
        }
        let win = Platform::Windows;
        let chord = Hotkey::parse("LeftCtrl+LeftAlt", win).unwrap();
        assert_eq!(chord, Hotkey::default_for(win));
        assert_eq!(chord.raw_value(win), "leftControl+leftOption");
        assert_eq!(Hotkey::parse("0x5D", win).unwrap().parts, vec![Part::Key(0x5D)]);
        assert_eq!(Hotkey::parse("0xA5", win).unwrap().parts, vec![Part::Mod(Modifier::RightAlt)]);
        assert_eq!(Hotkey::parse("Ctrl+Shift+Space", win).unwrap().parts.len(), 3);
        assert_eq!(Hotkey::parse("fn", win), None, "Fn never reaches a Windows hook");
        assert_eq!(Hotkey::parse("0x01", win), None, "the left button would take over clicking");
        assert_eq!(Hotkey::load("", win), Hotkey::default_for(win));
        assert_eq!(Hotkey::fn_key().label(mac), "Fn (Globe)");
        assert_eq!(chord.label(win), "Left Ctrl + Left Alt");
    }

    #[test]
    fn fn_is_pressed_and_released_and_its_own_change_swallowed() {
        let mut m = HotkeyMatcher::new(Hotkey::fn_key());
        let o = m.handle(&mods(&[Part::Fn], Some(Part::Fn)), 0.0);
        assert_eq!(o, Outcome { signal: Signal::Press, swallow: true, replay_click: false });
        let o = m.handle(&mods(&[], Some(Part::Fn)), 1.0);
        assert_eq!(o.signal, Signal::Release);
        // Shift changing while Fn is held is never swallowed.
        let mut m = HotkeyMatcher::new(Hotkey::fn_key());
        m.handle(&mods(&[Part::Fn], Some(Part::Fn)), 0.0);
        let o = m.handle(&mods(&[Part::Fn, Part::Mod(Modifier::LeftShift)], Some(Part::Mod(Modifier::LeftShift))), 0.1);
        assert!(!o.swallow);
    }

    #[test]
    fn a_chord_fires_on_its_last_part_and_ends_on_any_release() {
        let mut m = HotkeyMatcher::new(Hotkey::default_for(Platform::Windows));
        let ctrl = Part::Mod(Modifier::LeftControl);
        let alt = Part::Mod(Modifier::LeftAlt);
        assert_eq!(m.handle(&mods(&[ctrl], Some(ctrl)), 0.0).signal, Signal::None);
        assert_eq!(m.handle(&mods(&[ctrl, alt], Some(alt)), 0.1).signal, Signal::Press);
        assert_eq!(m.handle(&mods(&[alt], Some(ctrl)), 0.9).signal, Signal::Release);
    }

    #[test]
    fn a_quick_middle_click_is_handed_back() {
        let mut m = HotkeyMatcher::new(Hotkey { parts: vec![Part::Mouse(2)] });
        let down = m.handle(&HotkeyEvent::Mouse { button: 2, down: true }, 0.0);
        assert_eq!((down.signal, down.swallow), (Signal::Press, true));
        let up = m.handle(&HotkeyEvent::Mouse { button: 2, down: false }, 0.1);
        assert_eq!(up, Outcome { signal: Signal::Release, swallow: true, replay_click: true });
        m.handle(&HotkeyEvent::Mouse { button: 2, down: true }, 1.0);
        assert!(!m.handle(&HotkeyEvent::Mouse { button: 2, down: false }, 3.0).replay_click);
    }

    #[test]
    fn a_letter_in_a_chord_does_not_type() {
        let cmd = Part::Mod(Modifier::LeftMeta);
        let mut m = HotkeyMatcher::new(Hotkey { parts: vec![cmd, Part::Key(49)] });
        m.handle(&mods(&[cmd], Some(cmd)), 0.0);
        let o = m.handle(&HotkeyEvent::Key { code: 49, down: true, repeat: false }, 0.1);
        assert_eq!((o.signal, o.swallow), (Signal::Press, true));
        assert!(m.handle(&HotkeyEvent::Key { code: 49, down: true, repeat: true }, 0.2).swallow);
        let o = m.handle(&HotkeyEvent::Key { code: 49, down: false, repeat: false }, 0.5);
        assert_eq!((o.signal, o.swallow), (Signal::Release, true));
        // Space alone, with Command let go, types as usual.
        m.handle(&mods(&[], Some(cmd)), 0.8);
        let o = m.handle(&HotkeyEvent::Key { code: 49, down: true, repeat: false }, 1.0);
        assert!(!o.swallow);
    }

    #[test]
    fn recorder() {
        let mut r = HotkeyRecorder::default();
        let ctrl = Part::Mod(Modifier::LeftControl);
        assert_eq!(r.handle(&mods(&[ctrl], Some(ctrl)), MAC_ESCAPE), Recorded::Pending);
        assert_eq!(r.handle(&HotkeyEvent::Key { code: 49, down: true, repeat: false }, MAC_ESCAPE), Recorded::Pending);
        assert_eq!(r.handle(&HotkeyEvent::Key { code: 49, down: false, repeat: false }, MAC_ESCAPE), Recorded::Pending);
        assert_eq!(r.handle(&mods(&[], Some(ctrl)), MAC_ESCAPE), Recorded::Done(Hotkey { parts: vec![ctrl, Part::Key(49)] }));
        let mut r = HotkeyRecorder::default();
        r.handle(&HotkeyEvent::Key { code: MAC_ESCAPE, down: true, repeat: false }, MAC_ESCAPE);
        assert_eq!(r.handle(&HotkeyEvent::Key { code: MAC_ESCAPE, down: false, repeat: false }, MAC_ESCAPE), Recorded::Cancelled);
    }
}
