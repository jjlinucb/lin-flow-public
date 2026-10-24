//! Lin Flow Next: the service with its windows. The dashboard, the pill and the toasts are web
//! pages in TypeScript; everything they show comes from `linflow-service` as events, and
//! everything they do is a command below. The menu bar (tray) icon is the app's home.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod panel;

use linflow_core::history::HistoryEntry;
use linflow_core::notes::MeetingNote;
use linflow_core::settings::Settings;
use linflow_service::{DictationState, Event, NoteEvent, Service, ToastAction};
use serde::Serialize;
use std::sync::{Arc, Mutex};
use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem};
use tauri::tray::{TrayIcon, TrayIconBuilder};
use tauri::{AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, RunEvent, State, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};

const PILL_HEIGHT: f64 = 40.0;
const PILL_BOTTOM_MARGIN: f64 = 110.0;
const TOAST_WIDTH: f64 = 360.0;

struct Tray {
    icon: TrayIcon,
    status: MenuItem<tauri::Wry>,
    note: MenuItem<tauri::Wry>,
    pill: CheckMenuItem<tauri::Wry>,
}

struct App {
    svc: Arc<Service>,
    tray: Mutex<Option<Tray>>,
    /// The pill's size as its page last measured it.
    pill_width: Mutex<f64>,
}

type Cmd<T> = Result<T, String>;

/// A section of the main window to show: "dictation", "dictionary", "notes", "settings", or
/// "note:<id>".
#[derive(Clone, Serialize)]
struct Navigate {
    to: String,
}

fn main() {
    linflow_service::logging::start(cfg!(debug_assertions));
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| show_main(app, None)))
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let handle = app.handle().clone();
            let sink_handle = handle.clone();
            let svc = Service::start(Arc::new(move |e: Event| on_event(&sink_handle, e)));
            let settings = svc.ctx.settings();
            app.manage(App { svc: svc.clone(), tray: Mutex::new(None), pill_width: Mutex::new(220.0) });
            apply_dock(&handle, settings.show_in_dock);
            build_main(&handle, settings.open_window_at_launch)?;
            build_pill(&handle)?;
            build_toast(&handle)?;
            build_tray(&handle)?;
            if settings.show_hud {
                show_pill(&handle);
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            status,
            press,
            release,
            history,
            stats,
            delete_entry,
            edit_entry,
            retry_entry,
            recording_path,
            copy_text,
            dictionary,
            add_term,
            remove_term,
            add_rule,
            remove_rule,
            accept_rule,
            dismiss_rule,
            settings_view,
            set_settings,
            set_hotkey,
            record_hotkey,
            cancel_record_hotkey,
            request_access,
            notes,
            note,
            create_note,
            start_note,
            stop_note,
            rename_note,
            relabel_speaker,
            save_my_notes,
            delete_notes,
            summarize,
            recap,
            ask,
            transcribe_again,
            copy_markdown,
            save_markdown,
            reveal_note,
            open_data_folder,
            open_log,
            toast_action,
            toast_layout,
            toast_hide,
            pill_layout,
            pill_moved,
            hide_pill,
            pill_menu,
            quit,
        ])
        .build(tauri::generate_context!())
        .expect("Lin Flow Next could not start");
    app.run(|app, event| match event {
        // Closing the window hides it; only Quit quits.
        RunEvent::ExitRequested { api, code: None, .. } => api.prevent_exit(),
        RunEvent::Exit => shutdown(app),
        _ => {}
    });
}

/// Frees the model and closes an open meeting, then leaves with `_exit`: a normal exit with a
/// model loaded aborts in ggml's Metal teardown and macOS files a crash report.
fn shutdown(app: &AppHandle) -> ! {
    if let Some(state) = app.try_state::<App>() {
        state.svc.shutdown();
    }
    log::logger().flush();
    unsafe { libc::_exit(0) }
}

fn svc(app: &AppHandle) -> Arc<Service> {
    app.state::<App>().svc.clone()
}

// MARK: events

/// Every service event goes to every page; a few also move windows or the tray.
fn on_event(app: &AppHandle, event: Event) {
    let _ = app.emit("linflow", &event);
    match &event {
        Event::State { label, phase } => {
            let app2 = app.clone();
            let (label, phase) = (label.clone(), phase.clone());
            let _ = app.run_on_main_thread(move || update_tray(&app2, Some((&label, &phase))));
        }
        Event::Toast { .. } => {
            let app2 = app.clone();
            let _ = app.run_on_main_thread(move || {
                if let Some(w) = app2.get_webview_window("toast") {
                    panel::show(&w);
                }
            });
        }
        Event::Note { event: NoteEvent::Recording { .. } } | Event::SettingsChanged => {
            let app2 = app.clone();
            let _ = app.run_on_main_thread(move || update_tray(&app2, None));
        }
        _ => {}
    }
}

fn navigate(app: &AppHandle, to: &str) {
    show_main(app, Some(to));
}

fn show_main(app: &AppHandle, to: Option<&str>) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.show();
        let _ = w.unminimize();
        let _ = w.set_focus();
        if let Some(to) = to {
            let _ = w.emit("navigate", Navigate { to: to.into() });
        }
    }
}

// MARK: windows

fn build_main(app: &AppHandle, visible: bool) -> tauri::Result<()> {
    let w = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
        .title("Lin Flow Next")
        .inner_size(1100.0, 720.0)
        .min_inner_size(900.0, 560.0)
        .visible(visible)
        .build()?;
    let w2 = w.clone();
    w.on_window_event(move |e| {
        if let WindowEvent::CloseRequested { api, .. } = e {
            api.prevent_close();
            let _ = w2.hide();
        }
    });
    Ok(())
}

fn floating(app: &AppHandle, label: &str, page: &str, width: f64, height: f64) -> tauri::Result<WebviewWindow> {
    let builder = WebviewWindowBuilder::new(app, label, WebviewUrl::App(page.into()))
        .title(label)
        .inner_size(width, height)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .resizable(false)
        .focused(false)
        .visible(false)
        .visible_on_all_workspaces(true);
    #[cfg(target_os = "macos")]
    let builder = builder.accept_first_mouse(true);
    let w = builder.build()?;
    panel::make_floating(&w);
    Ok(w)
}

fn build_pill(app: &AppHandle) -> tauri::Result<()> {
    let w = floating(app, "pill", "pill.html", 220.0, PILL_HEIGHT)?;
    place_pill(app, &w, 220.0);
    Ok(())
}

fn build_toast(app: &AppHandle) -> tauri::Result<()> {
    floating(app, "toast", "toast.html", TOAST_WIDTH, 80.0)?;
    Ok(())
}

/// The primary screen in logical points: its size, and where its usable area starts.
fn screen(app: &AppHandle) -> (f64, f64, f64, f64) {
    let m = app.primary_monitor().ok().flatten();
    match m {
        Some(m) => {
            let scale = m.scale_factor();
            let area = m.work_area();
            (area.position.x as f64 / scale, area.position.y as f64 / scale, area.size.width as f64 / scale, area.size.height as f64 / scale)
        }
        None => (0.0, 0.0, 1440.0, 900.0),
    }
}

/// The saved spot when there is one, otherwise bottom center. Saved in the Mac app's own
/// convention on the Mac (from the bottom left of the main screen), so the setting carries over
/// at cutover; top left elsewhere.
fn place_pill(app: &AppHandle, w: &WebviewWindow, width: f64) {
    let s = svc(app).ctx.settings();
    let (x0, y0, sw, sh) = screen(app);
    let (x, y) = match (s.hud_x, s.hud_y) {
        (Some(x), Some(y)) if cfg!(target_os = "macos") => (x, y0 + sh - y - PILL_HEIGHT + y0),
        (Some(x), Some(y)) => (x, y),
        _ => (x0 + (sw - width) / 2.0, y0 + sh - PILL_BOTTOM_MARGIN - PILL_HEIGHT),
    };
    let x = x.clamp(x0 - width + 40.0, x0 + sw - 40.0);
    let y = y.clamp(y0, y0 + sh - PILL_HEIGHT);
    let _ = w.set_position(LogicalPosition::new(x, y));
}

fn show_pill(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("pill") {
        panel::show(&w);
    }
}

fn apply_dock(app: &AppHandle, show: bool) {
    #[cfg(target_os = "macos")]
    {
        let _ = app.set_activation_policy(if show { tauri::ActivationPolicy::Regular } else { tauri::ActivationPolicy::Accessory });
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (app, show);
}

// MARK: tray

fn build_tray(app: &AppHandle) -> tauri::Result<()> {
    let state = app.state::<App>();
    let status = MenuItem::with_id(app, "status", "Lin Flow Next", false, None::<&str>)?;
    let open = MenuItem::with_id(app, "open", "Open Lin Flow Next", true, None::<&str>)?;
    let note = MenuItem::with_id(app, "note", "Start Meeting Note", true, None::<&str>)?;
    let pill = CheckMenuItem::with_id(app, "pill", "Show Pill", true, state.svc.ctx.settings().show_hud, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit Lin Flow Next", true, None::<&str>)?;
    let menu = Menu::with_items(app, &[&status, &PredefinedMenuItem::separator(app)?, &open, &note, &pill, &PredefinedMenuItem::separator(app)?, &quit])?;
    let icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray@2x.png"))?;
    let tray = TrayIconBuilder::with_id("main")
        .icon(icon)
        .icon_as_template(true)
        .tooltip("Lin Flow Next")
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, e| match e.id().as_ref() {
            "open" => show_main(app, None),
            "note" => {
                let s = svc(app);
                if s.meetings.recording_id().is_some() {
                    s.stop_note();
                } else {
                    match s.start_note(None, None) {
                        Ok(id) => navigate(app, &format!("note:{id}")),
                        Err(e) => s.ctx.toast(linflow_service::Toast::new("Could not start the note", e).warning()),
                    }
                }
            }
            "pill" => {
                let show = !svc(app).ctx.settings().show_hud;
                set_pill_visible(app, show);
            }
            "quit" => shutdown(app),
            _ => {}
        })
        .build(app)?;
    *state.tray.lock().unwrap() = Some(Tray { icon: tray, status, note, pill });
    update_tray(app, None);
    Ok(())
}

fn update_tray(app: &AppHandle, state: Option<(&str, &str)>) {
    // The service starts, and sends its first states, before setup manages `App`, and on the
    // Mac those calls run at once on the main thread. `state()` would panic there, inside
    // did_finish_launching, which cannot unwind: the app aborted 0.3 s after every launch.
    // There is no tray yet either; `build_tray` brings it up to date.
    let Some(app_state) = app.try_state::<App>() else { return };
    let s = app_state.svc.clone();
    let st = s.status();
    let (label, phase) = state.map(|(l, p)| (l.to_string(), p.to_string())).unwrap_or((st.label.clone(), st.phase.clone()));
    let guard = app_state.tray.lock().unwrap();
    let Some(t) = guard.as_ref() else { return };
    let line = if phase == "idle" { format!("Hold {} to talk", st.hotkey_label) } else { label };
    let _ = t.status.set_text(line);
    let recording = s.meetings.recording_id().is_some();
    let _ = t.note.set_text(if recording { "Stop Meeting Note" } else { "Start Meeting Note" });
    let _ = t.pill.set_checked(s.ctx.settings().show_hud);
    let busy = phase == "recording" || recording;
    let bytes: &[u8] = if busy { include_bytes!("../icons/tray-recording.png") } else { include_bytes!("../icons/tray@2x.png") };
    if let Ok(img) = tauri::image::Image::from_bytes(bytes) {
        let _ = t.icon.set_icon(Some(img));
        let _ = t.icon.set_icon_as_template(!busy);
    }
}

fn set_pill_visible(app: &AppHandle, show: bool) {
    svc(app).ctx.update_settings(|s| s.show_hud = show);
    if let Some(w) = app.get_webview_window("pill") {
        if show {
            panel::show(&w);
        } else {
            panel::hide(&w);
        }
    }
    update_tray(app, None);
}

// MARK: commands: status and the pill

#[tauri::command]
fn status(app: State<'_, App>) -> linflow_service::StatusView {
    app.svc.status()
}

#[tauri::command]
fn press(app: State<'_, App>) {
    app.svc.dictation.press();
}

#[tauri::command]
fn release(app: State<'_, App>) {
    app.svc.dictation.release();
}

/// The pill page measured itself: fit the window to it.
#[tauri::command]
fn pill_layout(handle: AppHandle, app: State<'_, App>, width: f64) {
    let Some(w) = handle.get_webview_window("pill") else { return };
    let old = std::mem::replace(&mut *app.pill_width.lock().unwrap(), width);
    if (old - width).abs() < 0.5 {
        return;
    }
    // Grow and shrink around the left edge, as the Mac pill does.
    let _ = w.set_size(LogicalSize::new(width, PILL_HEIGHT));
}

/// The pill was dragged: remember where.
#[tauri::command]
fn pill_moved(handle: AppHandle, app: State<'_, App>) {
    let Some(w) = handle.get_webview_window("pill") else { return };
    let Ok(pos) = w.outer_position() else { return };
    let scale = w.scale_factor().unwrap_or(1.0);
    let (x, y) = (pos.x as f64 / scale, pos.y as f64 / scale);
    let (_, y0, _, sh) = screen(&handle);
    let saved_y = if cfg!(target_os = "macos") { y0 + sh - y - PILL_HEIGHT + y0 } else { y };
    app.svc.ctx.update_settings(|s| {
        s.hud_x = Some(x);
        s.hud_y = Some(saved_y);
    });
}

#[tauri::command]
fn hide_pill(handle: AppHandle) {
    set_pill_visible(&handle, false);
}

/// The pill's click menu: the main window's sections, and a meeting note.
#[tauri::command]
fn pill_menu(handle: AppHandle, item: String) {
    match item.as_str() {
        "note" => {
            let s = svc(&handle);
            if s.meetings.recording_id().is_some() {
                s.stop_note();
            } else if let Ok(id) = s.start_note(None, None) {
                navigate(&handle, &format!("note:{id}"));
            }
        }
        other => navigate(&handle, other),
    }
}

// MARK: commands: toasts

#[tauri::command]
fn toast_action(handle: AppHandle, app: State<'_, App>, action: ToastAction) {
    let svc = app.svc.clone();
    // Off the main thread: starting or stopping a meeting takes a moment.
    std::thread::spawn(move || {
        if let Some(to) = svc.toast_action(action) {
            if let Some(path) = to.strip_prefix("open:") {
                use tauri_plugin_opener::OpenerExt;
                let _ = handle.opener().open_path(path, None::<&str>);
            } else {
                let h = handle.clone();
                let _ = handle.run_on_main_thread(move || navigate(&h, &to));
            }
        }
    });
}

/// The toast page measured its stack: fit the window and put it above the pill.
#[tauri::command]
fn toast_layout(handle: AppHandle, app: State<'_, App>, height: f64) {
    let Some(w) = handle.get_webview_window("toast") else { return };
    let height = height.max(10.0);
    let _ = w.set_size(LogicalSize::new(TOAST_WIDTH, height));
    let (x0, y0, sw, sh) = screen(&handle);
    let pill = handle.get_webview_window("pill").filter(|_| app.svc.ctx.settings().show_hud);
    let (x, y) = match pill.and_then(|p| Some((p.outer_position().ok()?, p.scale_factor().ok()?))) {
        Some((pos, scale)) => {
            let (px, py) = (pos.x as f64 / scale, pos.y as f64 / scale);
            let width = *app.pill_width.lock().unwrap();
            let x = px + width / 2.0 - TOAST_WIDTH / 2.0;
            // Above the pill when there is room, below it when there is not.
            let y = if py - 8.0 - height >= y0 { py - 8.0 - height } else { py + PILL_HEIGHT + 8.0 };
            (x, y)
        }
        None => (x0 + (sw - TOAST_WIDTH) / 2.0, y0 + sh - 150.0 - height),
    };
    let x = x.clamp(x0 + 8.0, (x0 + sw - TOAST_WIDTH - 8.0).max(x0 + 8.0));
    let y = y.clamp(y0 + 8.0, (y0 + sh - height - 8.0).max(y0 + 8.0));
    let _ = w.set_position(LogicalPosition::new(x, y));
    panel::show(&w);
}

#[tauri::command]
fn toast_hide(handle: AppHandle) {
    if let Some(w) = handle.get_webview_window("toast") {
        panel::hide(&w);
    }
}

// MARK: commands: dictations

#[tauri::command]
fn history(app: State<'_, App>) -> Vec<HistoryEntry> {
    app.svc.history()
}

#[tauri::command]
fn stats(app: State<'_, App>) -> linflow_service::StatsView {
    app.svc.stats()
}

#[tauri::command]
fn delete_entry(app: State<'_, App>, id: String) -> Cmd<()> {
    app.svc.delete_entry(&id)
}

#[tauri::command]
async fn edit_entry(app: State<'_, App>, id: String, text: String) -> Cmd<()> {
    app.svc.edit_entry(&id, &text)
}

#[tauri::command]
async fn retry_entry(app: State<'_, App>, id: String) -> Cmd<HistoryEntry> {
    app.svc.retry_entry(&id)
}

#[tauri::command]
fn recording_path(app: State<'_, App>, id: String) -> Option<String> {
    app.svc.audio_path(&id)
}

#[tauri::command]
fn copy_text(text: String) {
    linflow_platform::copy(&text);
}

// MARK: commands: dictionary

#[tauri::command]
fn dictionary(app: State<'_, App>) -> linflow_service::DictionaryView {
    app.svc.dictionary()
}

#[tauri::command]
fn add_term(app: State<'_, App>, term: String) -> Cmd<()> {
    app.svc.ctx.dictionary.add_term(&term).map_err(|e| e.to_string())
}

#[tauri::command]
fn remove_term(app: State<'_, App>, term: String) -> Cmd<()> {
    app.svc.ctx.dictionary.remove_term(&term).map_err(|e| e.to_string())
}

#[tauri::command]
fn add_rule(app: State<'_, App>, from: String, to: String) -> Cmd<()> {
    app.svc.ctx.dictionary.add_rule(&from, &to).map_err(|e| e.to_string())
}

#[tauri::command]
fn remove_rule(app: State<'_, App>, from: String) -> Cmd<()> {
    app.svc.ctx.dictionary.remove_rule(&from).map_err(|e| e.to_string())
}

#[tauri::command]
fn accept_rule(app: State<'_, App>, from: String, to: String) -> Cmd<()> {
    app.svc.ctx.dictionary.accept(&from, &to).map_err(|e| e.to_string())
}

#[tauri::command]
fn dismiss_rule(app: State<'_, App>, from: String) -> Cmd<()> {
    app.svc.ctx.dictionary.dismiss(&from).map_err(|e| e.to_string())
}

// MARK: commands: settings

#[tauri::command]
fn settings_view(app: State<'_, App>) -> linflow_service::SettingsView {
    app.svc.settings_view()
}

#[tauri::command]
fn set_settings(handle: AppHandle, app: State<'_, App>, settings: Settings) {
    let old = app.svc.ctx.settings();
    app.svc.set_settings(settings.clone());
    if old.show_in_dock != settings.show_in_dock {
        apply_dock(&handle, settings.show_in_dock);
    }
    if old.show_hud != settings.show_hud {
        set_pill_visible(&handle, settings.show_hud);
    }
    if old.launch_at_login != settings.launch_at_login {
        use tauri_plugin_autostart::ManagerExt;
        let launcher = handle.autolaunch();
        let result = if settings.launch_at_login { launcher.enable() } else { launcher.disable() };
        if let Err(e) = result {
            log::warn!("launch at login: {e}");
        }
    }
}

#[tauri::command]
fn set_hotkey(app: State<'_, App>, raw: String) -> Cmd<()> {
    app.svc.set_hotkey(&raw)
}

#[tauri::command]
fn record_hotkey(app: State<'_, App>) {
    app.svc.record_hotkey();
}

#[tauri::command]
fn cancel_record_hotkey(app: State<'_, App>) {
    app.svc.cancel_record_hotkey();
}

#[tauri::command]
fn request_access(app: State<'_, App>) -> bool {
    app.svc.request_access()
}

#[tauri::command]
fn open_data_folder(handle: AppHandle, app: State<'_, App>) {
    use tauri_plugin_opener::OpenerExt;
    let _ = handle.opener().open_path(app.svc.ctx.data_dir.display().to_string(), None::<&str>);
}

#[tauri::command]
fn open_log(handle: AppHandle) {
    use tauri_plugin_opener::OpenerExt;
    let _ = handle.opener().open_path(linflow_service::logging::path().display().to_string(), None::<&str>);
}

// MARK: commands: notes

#[tauri::command]
fn notes(app: State<'_, App>) -> Vec<MeetingNote> {
    app.svc.notes()
}

#[tauri::command]
fn note(app: State<'_, App>, id: String) -> Option<linflow_service::NoteDetail> {
    app.svc.note(&id)
}

#[tauri::command]
fn create_note(app: State<'_, App>) -> Cmd<MeetingNote> {
    app.svc.create_note()
}

#[tauri::command]
async fn start_note(app: State<'_, App>, id: Option<String>) -> Cmd<String> {
    app.svc.start_note(id.as_deref(), None)
}

#[tauri::command]
async fn stop_note(app: State<'_, App>) -> Cmd<Option<String>> {
    Ok(app.svc.stop_note())
}

#[tauri::command]
fn rename_note(app: State<'_, App>, id: String, title: String) -> Cmd<MeetingNote> {
    app.svc.rename_note(&id, &title)
}

#[tauri::command]
fn relabel_speaker(app: State<'_, App>, id: String, from: String, to: String) -> Cmd<()> {
    app.svc.relabel_speaker(&id, &from, &to)
}

#[tauri::command]
fn save_my_notes(app: State<'_, App>, id: String, text: String) -> Cmd<()> {
    app.svc.save_my_notes(&id, &text)
}

#[tauri::command]
fn delete_notes(app: State<'_, App>, ids: Vec<String>) -> Cmd<()> {
    app.svc.delete_notes(&ids, &|p: &std::path::Path| trash::delete(p).map_err(std::io::Error::other))
}

#[tauri::command]
fn summarize(app: State<'_, App>, id: String) {
    app.svc.summarize(&id);
}

#[tauri::command]
fn recap(app: State<'_, App>, id: String, minutes: f64) {
    app.svc.recap(&id, minutes);
}

#[tauri::command]
fn ask(app: State<'_, App>, id: String, question: String) {
    app.svc.ask(&id, &question);
}

#[tauri::command]
fn transcribe_again(app: State<'_, App>, id: String) -> Cmd<()> {
    app.svc.transcribe_again(&id)
}

#[tauri::command]
fn copy_markdown(app: State<'_, App>, id: String) -> Cmd<()> {
    let md = app.svc.note_markdown(&id).ok_or("That meeting is gone.")?;
    linflow_platform::copy(&md);
    Ok(())
}

#[tauri::command]
async fn save_markdown(handle: AppHandle, app: State<'_, App>, id: String) -> Cmd<bool> {
    use tauri_plugin_dialog::DialogExt;
    let md = app.svc.note_markdown(&id).ok_or("That meeting is gone.")?;
    let title = app.svc.ctx.notes.load(&id).map(|n| n.title).unwrap_or_else(|| "Meeting".into());
    let Some(path) = handle.dialog().file().set_file_name(format!("{}.md", title.replace('/', "-"))).add_filter("Markdown", &["md"]).blocking_save_file() else {
        return Ok(false);
    };
    let path = path.into_path().map_err(|e| e.to_string())?;
    std::fs::write(path, md).map_err(|e| e.to_string())?;
    Ok(true)
}

#[tauri::command]
fn reveal_note(handle: AppHandle, app: State<'_, App>, id: String) {
    use tauri_plugin_opener::OpenerExt;
    let _ = handle.opener().reveal_item_in_dir(app.svc.ctx.notes.folder(&id));
}

#[tauri::command]
fn quit(handle: AppHandle) {
    shutdown(&handle);
}

#[allow(dead_code)]
fn _state_is_used(_: DictationState) {}
