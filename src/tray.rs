use windows::core::{w, Result, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, DeleteObject, GetMonitorInfoW, GetSysColorBrush, MonitorFromPoint, COLOR_BTNFACE,
    HFONT, MONITORINFO, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::Controls::{
    InitCommonControlsEx, ICC_BAR_CLASSES, INITCOMMONCONTROLSEX, TBM_SETPOS, TBM_SETRANGE,
    TBS_AUTOTICKS,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::*;

pub const CHANGED: u32 = WM_APP + 8;
pub const CLOSED: u32 = WM_APP + 9;
const VOICE: usize = 10;
const LANGUAGE: usize = 11;
const OCR_ENGINE: usize = 12;

pub struct Options {
    pub rate: i32,
    pub voices: Vec<String>,
    pub voice_index: usize,
    pub languages: Vec<String>,
    pub language_index: usize,
    pub tiny_ocr: bool,
    pub startup: bool,
    pub read_hotkey: String,
    pub capture_hotkey: String,
    pub copy_hotkey: String,
    pub stop_hotkey: String,
}

struct State {
    owner: HWND,
    slider: HWND,
    label: HWND,
    font: HFONT,
}

pub fn show(owner: HWND, existing: Option<HWND>, options: &Options) -> Result<HWND> {
    unsafe {
        if let Some(hwnd) = existing.filter(|hwnd| IsWindow(*hwnd).as_bool()) {
            let _ = SetForegroundWindow(hwnd);
            return Ok(hwnd);
        }
        InitCommonControlsEx(&INITCOMMONCONTROLSEX {
            dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_BAR_CLASSES,
        })
        .ok()?;
        super::register_window_class("InstaSpeakTrayPanel", Some(window_proc), IDC_ARROW)?;
        let mut point = POINT::default();
        GetCursorPos(&mut point)?;
        let state = Box::into_raw(Box::new(State {
            owner,
            slider: HWND::default(),
            label: HWND::default(),
            font: HFONT::default(),
        }));
        let hwnd = match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT | WS_EX_TOPMOST,
            w!("InstaSpeakTrayPanel"),
            w!("InstaSpeak"),
            WS_POPUP | WS_BORDER,
            point.x - 360,
            point.y - 500,
            360,
            500,
            None,
            None,
            None,
            Some(state as _),
        ) {
            Ok(hwnd) => hwnd,
            Err(error) => {
                drop(Box::from_raw(state));
                return Err(error);
            }
        };
        SetClassLongPtrW(
            hwnd,
            GCLP_HBRBACKGROUND,
            GetSysColorBrush(COLOR_BTNFACE).0 as isize,
        );
        if let Err(error) = create_controls(hwnd, &mut *state, options, point) {
            let _ = DestroyWindow(hwnd);
            return Err(error);
        }
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus((*state).slider);
        Ok(hwnd)
    }
}

unsafe fn create_controls(
    hwnd: HWND,
    state: &mut State,
    options: &Options,
    point: POINT,
) -> Result<()> {
    let dpi = GetDpiForWindow(hwnd).max(96) as i32;
    let scale = |value: i32| value * dpi / 96;
    let mut monitor = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    GetMonitorInfoW(
        MonitorFromPoint(point, MONITOR_DEFAULTTONEAREST),
        &mut monitor,
    )
    .ok()?;
    let work = monitor.rcWork;
    let x = (point.x - scale(360)).clamp(work.left, (work.right - scale(360)).max(work.left));
    let y = (point.y - scale(500)).clamp(work.top, (work.bottom - scale(500)).max(work.top));
    SetWindowPos(hwnd, None, x, y, scale(360), scale(500), SWP_NOZORDER)?;
    state.font = CreateFontW(
        -scale(14),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        1,
        0,
        0,
        5,
        0,
        w!("Segoe UI"),
    );
    let control = |class, text: &str, style, id, x, y, width, height| -> Result<HWND> {
        let text = super::wide_null(text);
        let child = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            class,
            PCWSTR(text.as_ptr()),
            WS_CHILD | WS_VISIBLE | style,
            scale(x),
            scale(y),
            scale(width),
            scale(height),
            hwnd,
            HMENU(id as _),
            None,
            None,
        )?;
        SendMessageW(child, WM_SETFONT, WPARAM(state.font.0 as usize), LPARAM(1));
        Ok(child)
    };
    control(
        w!("STATIC"),
        "InstaSpeak  |  OCR and speech",
        WINDOW_STYLE(0),
        0,
        16,
        14,
        328,
        24,
    )?;
    for (id, text, y) in [
        (
            super::IDM_SELECTED,
            format!("Read selected text     {}", options.read_hotkey),
            48,
        ),
        (
            super::IDM_CAPTURE,
            format!("Capture and read     {}", options.capture_hotkey),
            84,
        ),
        (
            super::IDM_COPY,
            format!("Capture and copy     {}", options.copy_hotkey),
            120,
        ),
        (
            super::IDM_STOP,
            format!("Stop reading     {}", options.stop_hotkey),
            156,
        ),
    ] {
        control(
            w!("BUTTON"),
            &text,
            WS_TABSTOP | WINDOW_STYLE(BS_LEFT as u32),
            id,
            16,
            y,
            328,
            32,
        )?;
    }
    state.label = control(
        w!("STATIC"),
        &rate_label(options.rate),
        WINDOW_STYLE(0),
        0,
        16,
        202,
        328,
        24,
    )?;
    state.slider = control(
        w!("msctls_trackbar32"),
        "Speech speed",
        WS_TABSTOP | WINDOW_STYLE(TBS_AUTOTICKS),
        1,
        12,
        228,
        336,
        36,
    )?;
    SendMessageW(state.slider, TBM_SETRANGE, WPARAM(1), LPARAM(20 << 16));
    SendMessageW(
        state.slider,
        TBM_SETPOS,
        WPARAM(1),
        LPARAM((options.rate + 10) as isize),
    );
    control(w!("STATIC"), "Slowest", WINDOW_STYLE(0), 0, 16, 266, 80, 20)?;
    control(w!("STATIC"), "Normal", WINDOW_STYLE(0), 0, 150, 266, 80, 20)?;
    control(
        w!("STATIC"),
        "Fastest",
        WINDOW_STYLE(0),
        0,
        292,
        266,
        60,
        20,
    )?;
    let engines = vec![
        "Windows OCR".to_string(),
        if super::tiny::assets().is_some() {
            "PP-OCRv6 Tiny"
        } else {
            "PP-OCRv6 Tiny (install required)"
        }
        .to_string(),
    ];
    for (id, name, entries, selected, y) in [
        (VOICE, "Voice", &options.voices, options.voice_index, 290),
        (
            OCR_ENGINE,
            "OCR engine",
            &engines,
            usize::from(options.tiny_ocr),
            344,
        ),
        (
            LANGUAGE,
            "Windows OCR language",
            &options.languages,
            options.language_index,
            398,
        ),
    ] {
        control(w!("STATIC"), name, WINDOW_STYLE(0), 0, 16, y, 328, 22)?;
        let combo = control(
            w!("COMBOBOX"),
            "",
            WS_TABSTOP | WS_VSCROLL | WINDOW_STYLE(CBS_DROPDOWNLIST as u32),
            id,
            16,
            y + 22,
            328,
            180,
        )?;
        for text in entries {
            let text = super::wide_null(text);
            SendMessageW(
                combo,
                CB_ADDSTRING,
                WPARAM(0),
                LPARAM(text.as_ptr() as isize),
            );
        }
        SendMessageW(combo, CB_SETCURSEL, WPARAM(selected), LPARAM(0));
    }
    let startup = control(
        w!("BUTTON"),
        "Start with Windows",
        WS_TABSTOP | WINDOW_STYLE(BS_AUTOCHECKBOX as u32),
        super::IDM_TOGGLE_STARTUP,
        16,
        460,
        240,
        26,
    )?;
    SendMessageW(
        startup,
        BM_SETCHECK,
        WPARAM(usize::from(options.startup)),
        LPARAM(0),
    );
    control(
        w!("BUTTON"),
        "Exit",
        WS_TABSTOP,
        super::IDM_EXIT,
        274,
        459,
        70,
        28,
    )?;
    Ok(())
}

fn rate_label(rate: i32) -> String {
    if rate == 0 {
        "Speech speed: normal".to_string()
    } else {
        format!("Speech speed: {rate:+}")
    }
}

unsafe extern "system" fn window_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    if msg == WM_NCCREATE {
        let create = &*(lparam.0 as *const CREATESTRUCTW);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, create.lpCreateParams as isize);
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut State;
    let Some(state) = ptr.as_mut() else {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    };
    match msg {
        WM_HSCROLL if lparam.0 == state.slider.0 as isize => {
            let position = SendMessageW(state.slider, WM_USER, WPARAM(0), LPARAM(0)).0;
            let text = super::wide_null(&rate_label(position as i32 - 10));
            let _ = SetWindowTextW(state.label, PCWSTR(text.as_ptr()));
            let _ = PostMessageW(state.owner, CHANGED, WPARAM(position as usize), LPARAM(0));
            LRESULT(0)
        }
        WM_COMMAND => {
            let id = wparam.0 & 0xffff;
            let notification = (wparam.0 >> 16) as u32;
            if (id == VOICE || id == LANGUAGE || id == OCR_ENGINE) && notification == CBN_SELCHANGE
            {
                let index = SendMessageW(HWND(lparam.0 as _), CB_GETCURSEL, WPARAM(0), LPARAM(0)).0;
                if index >= 0 {
                    let command = if id == VOICE {
                        super::IDM_VOICE_BASE
                    } else if id == LANGUAGE {
                        super::IDM_LANGUAGE_BASE
                    } else {
                        super::IDM_OCR_ENGINE_BASE
                    } + index as usize;
                    let _ = PostMessageW(state.owner, WM_COMMAND, WPARAM(command), LPARAM(0));
                }
            } else if id == 2 {
                let _ = DestroyWindow(hwnd);
            } else if id == super::IDM_TOGGLE_STARTUP {
                let _ = PostMessageW(state.owner, WM_COMMAND, WPARAM(id), LPARAM(0));
            } else if [
                super::IDM_SELECTED,
                super::IDM_CAPTURE,
                super::IDM_COPY,
                super::IDM_STOP,
                super::IDM_EXIT,
            ]
            .contains(&id)
            {
                let _ = PostMessageW(state.owner, WM_COMMAND, WPARAM(id), LPARAM(0));
                let _ = DestroyWindow(hwnd);
            }
            LRESULT(0)
        }
        WM_ACTIVATE if wparam.0 & 0xffff == WA_INACTIVE as usize => {
            let _ = PostMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
            LRESULT(0)
        }
        WM_NCDESTROY => {
            let _ = PostMessageW(state.owner, CLOSED, WPARAM(hwnd.0 as usize), LPARAM(0));
            if !state.font.0.is_null() {
                let _ = DeleteObject(state.font);
            }
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            drop(Box::from_raw(ptr));
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
