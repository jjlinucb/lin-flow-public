//! Two small facts about the computer: its name, and the free space on the disk under a folder.

/// This computer's name, for a sync.env that does not give one: the Windows computer name, or
/// the host name without the Mac's ".local".
pub fn computer_name() -> String {
    if let Ok(name) = std::env::var("COMPUTERNAME") {
        return name;
    }
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        if unsafe { libc::gethostname(buf.as_mut_ptr() as *mut libc::c_char, buf.len()) } == 0 {
            let end = buf.iter().position(|&b| b == 0).unwrap_or(buf.len());
            let name = String::from_utf8_lossy(&buf[..end]).to_string();
            return name.trim_end_matches(".local").to_string();
        }
    }
    "this computer".into()
}

/// Bytes free to this user on the disk holding `path`, which is created first if missing.
pub fn free_bytes(path: &std::path::Path) -> Option<u64> {
    let _ = std::fs::create_dir_all(path);
    imp::free_bytes(path)
}

#[cfg(unix)]
mod imp {
    pub fn free_bytes(path: &std::path::Path) -> Option<u64> {
        let c = std::ffi::CString::new(path.to_string_lossy().as_bytes()).ok()?;
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        (unsafe { libc::statvfs(c.as_ptr(), &mut st) } == 0).then(|| st.f_bavail as u64 * st.f_frsize as u64)
    }
}

#[cfg(windows)]
mod imp {
    use windows::core::HSTRING;
    use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;

    pub fn free_bytes(path: &std::path::Path) -> Option<u64> {
        let mut free = 0u64;
        unsafe { GetDiskFreeSpaceExW(&HSTRING::from(path.as_os_str()), Some(&mut free), None, None) }.ok()?;
        Some(free)
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_temp_folder_has_room_and_the_computer_a_name() {
        assert!(super::free_bytes(&std::env::temp_dir()).is_some_and(|b| b > 0));
        assert!(!super::computer_name().is_empty());
    }
}
