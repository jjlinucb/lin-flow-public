//! The four sounds: ready, start, stop and error. The Mac plays its own system sounds as the
//! Swift app did (Glass, Tink, Pop, Basso); Windows plays its speech on and off sounds, which the
//! Windows app never had. Each call returns at once and the sound plays on its own.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Sound {
    Ready,
    Start,
    Stop,
    Error,
}

#[cfg(target_os = "macos")]
mod imp {
    use super::Sound;
    use objc2::rc::Retained;
    use objc2::AnyThread;
    use objc2_app_kit::NSSound;
    use objc2_foundation::NSString;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct Cached(Retained<NSSound>);
    // Played under the lock below, one call at a time.
    unsafe impl Send for Cached {}

    static CACHE: Mutex<Option<HashMap<Sound, Cached>>> = Mutex::new(None);

    fn file(sound: Sound) -> &'static str {
        match sound {
            Sound::Ready => "/System/Library/Sounds/Glass.aiff",
            Sound::Start => "/System/Library/Sounds/Tink.aiff",
            Sound::Stop => "/System/Library/Sounds/Pop.aiff",
            Sound::Error => "/System/Library/Sounds/Basso.aiff",
        }
    }

    pub fn play(sound: Sound) {
        let Ok(mut guard) = CACHE.lock() else { return };
        let cache = guard.get_or_insert_with(HashMap::new);
        if let std::collections::hash_map::Entry::Vacant(slot) = cache.entry(sound) {
            let path = NSString::from_str(file(sound));
            let Some(s) = NSSound::initWithContentsOfFile_byReference(NSSound::alloc(), &path, true) else { return };
            slot.insert(Cached(s));
        }
        if let Some(Cached(s)) = cache.get(&sound) {
            // A sound still playing from the last take starts again rather than being skipped.
            s.stop();
            s.play();
        }
    }
}

#[cfg(windows)]
mod imp {
    use super::Sound;
    use windows::core::{w, PCWSTR};
    use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_FILENAME, SND_NODEFAULT};

    fn file(sound: Sound) -> PCWSTR {
        match sound {
            Sound::Ready => w!("C:\\Windows\\Media\\Windows Notify System Generic.wav"),
            Sound::Start => w!("C:\\Windows\\Media\\Speech On.wav"),
            Sound::Stop => w!("C:\\Windows\\Media\\Speech Off.wav"),
            Sound::Error => w!("C:\\Windows\\Media\\Windows Critical Stop.wav"),
        }
    }

    pub fn play(sound: Sound) {
        // A missing file plays nothing rather than the default beep.
        unsafe {
            let _ = PlaySoundW(file(sound), None, SND_FILENAME | SND_ASYNC | SND_NODEFAULT);
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    pub fn play(_sound: super::Sound) {}
}

pub use imp::play;
