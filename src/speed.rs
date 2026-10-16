use windows::core::{w, Result, PCWSTR};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    CreateFontW, DeleteObject, GetMonitorInfoW, GetSysColorBrush, MonitorFromWindow, COLOR_BTNFACE,
    HFONT, MONITORINFO, MONITOR_DEFAULTTONEAREST,
};
use windows::Win32::UI::Controls::{
    InitCommonControlsEx, ICC_BAR_CLASSES, INITCOMMONCONTROLSEX, TBM_SETPOS, TBM_SETRANGE,
    TBS_AUTOTICKS, TRACKBAR_CLASSW,
};
use windows::Win32::UI::HiDpi::GetDpiForWindow;
use windows::Win32::UI::Input::KeyboardAndMouse::SetFocus;
use windows::Win32::UI::WindowsAndMessaging::*;

pub const CHANGED: u32 = WM_APP + 8;
pub const CLOSED: u32 = WM_APP + 9;
const TBM_GETPOS: u32 = WM_USER;

struct State {
    owner: HWND,
    slider: HWND,
    label: HWND,
    font: HFONT,
}

pub fn show(owner: HWND, existing: Option<HWND>, rate: i32) -> Result<HWND> {
    unsafe {
        if let Some(hwnd) = existing {
            let _ = ShowWindow(hwnd, SW_SHOW);
            let _ = SetForegroundWindow(hwnd);
            return Ok(hwnd);
        }
        let controls = INITCOMMONCONTROLSEX {
            dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_BAR_CLASSES,
        };
        InitCommonControlsEx(&controls).ok()?;
        super::register_window_class("InstaSpeakSpeedWindow", Some(window_proc), IDC_ARROW)?;
        let mut point = POINT::default();
        GetCursorPos(&mut point)?;
        let state = Box::into_raw(Box::new(State {
            owner,
            slider: HWND::default(),
            label: HWND::default(),
            font: HFONT::default(),
        }));
        let hwnd = match CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_CONTROLPARENT,
            w!("InstaSpeakSpeedWindow"),
            w!("Reading speed"),
            WS_CAPTION | WS_SYSMENU,
            point.x - 340,
            point.y - 190,
            360,
            185,
            owner,
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
        if let Err(error) = create_controls(hwnd, &mut *state, rate) {
            let _ = DestroyWindow(hwnd);
            return Err(error);
        }
        let _ = ShowWindow(hwnd, SW_SHOW);
        let _ = SetForegroundWindow(hwnd);
        let _ = SetFocus((*state).slider);
        Ok(hwnd)
    }
}

unsafe fn create_controls(hwnd: HWND, state: &mut State, rate: i32) -> Result<()> {
    let dpi = GetDpiForWindow(hwnd).max(96) as i32;
    let scale = |value: i32| value * dpi / 96;
    let mut bounds = RECT::default();
    GetWindowRect(hwnd, &mut bounds)?;
    let mut monitor = MONITORINFO {
        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    GetMonitorInfoW(
        MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
        &mut monitor,
    )
    .ok()?;
    let work = monitor.rcWork;
    let x = bounds
        .left
        .clamp(work.left, (work.right - scale(360)).max(work.left));
    let y = bounds
        .top
        .clamp(work.top, (work.bottom - scale(185)).max(work.top));
    SetWindowPos(hwnd, None, x, y, scale(360), scale(185), SWP_NOZORDER)?;
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
    let make_label = |text: &str, x, y, width| -> Result<HWND> {
        let text = super::wide_null(text);
        let label = CreateWindowExW(
            WINDOW_EX_STYLE(0),
            w!("STATIC"),
            PCWSTR(text.as_ptr()),
            WS_CHILD | WS_VISIBLE,
            scale(x),
            scale(y),
            scale(width),
            scale(24),
            hwnd,
            None,
            None,
            None,
        )?;
        SendMessageW(label, WM_SETFONT, WPARAM(state.font.0 as usize), LPARAM(1));
        Ok(label)
    };
    state.label = make_label(&rate_label(rate), 20, 15, 310)?;
    state.slider = CreateWindowExW(
        WINDOW_EX_STYLE(0),
        TRACKBAR_CLASSW,
        w!("Speech speed"),
        WS_CHILD | WS_VISIBLE | WS_TABSTOP | WINDOW_STYLE(TBS_AUTOTICKS),
        scale(15),
        scale(46),
        scale(320),
        scale(42),
        hwnd,
        HMENU(1 as _),
        None,
        None,
    )?;
    SendMessageW(state.slider, TBM_SETRANGE, WPARAM(1), LPARAM(20 << 16));
    SendMessageW(
        state.slider,
        TBM_SETPOS,
        WPARAM(1),
        LPARAM((rate + 10) as isize),
    );
    make_label("Slowest", 20, 92, 80)?;
    make_label("Normal", 148, 92, 80)?;
    make_label("Fastest", 280, 92, 65)?;
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
        return LRESULT(1);
    }
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut State;
    let Some(state) = ptr.as_mut() else {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    };
    match msg {
        WM_HSCROLL if lparam.0 == state.slider.0 as isize => {
            let position = SendMessageW(state.slider, TBM_GETPOS, WPARAM(0), LPARAM(0)).0;
            let text = super::wide_null(&rate_label(position as i32 - 10));
            let _ = SetWindowTextW(state.label, PCWSTR(text.as_ptr()));
            let _ = PostMessageW(state.owner, CHANGED, WPARAM(position as usize), LPARAM(0));
            LRESULT(0)
        }
        WM_COMMAND if wparam.0 & 0xffff == 2 => {
            let _ = DestroyWindow(hwnd);
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
