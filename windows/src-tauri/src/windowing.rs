//! 浮岛主窗口的几何与原生策略。纯几何可独立运行 `rustc --test`，不依赖桌面运行时。

use std::collections::HashMap;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PixelPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PixelRect {
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
}

impl PixelRect {
    pub fn right(self) -> f64 { self.x as f64 + self.width as f64 }
    pub fn bottom(self) -> f64 { self.y as f64 + self.height as f64 }
    pub fn contains(self, point: PixelPoint) -> bool {
        point.x >= self.x as f64 && point.x < self.right()
            && point.y >= self.y as f64 && point.y < self.bottom()
    }
    pub fn intersection_area(self, other: Self) -> f64 {
        let width = (self.right().min(other.right()) - (self.x as f64).max(other.x as f64)).max(0.0);
        let height = (self.bottom().min(other.bottom()) - (self.y as f64).max(other.y as f64)).max(0.0);
        width * height
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DisplayGeometry {
    pub id: String,
    pub bounds: PixelRect,
    pub scale_factor: f64,
    pub primary: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Placement {
    pub monitor_id: String,
    pub rect: PixelRect,
    pub scale_factor: f64,
}

/// 尺寸按目标屏幕 DPI 转为物理像素；屏幕坐标本来就是物理像素，不能再次乘 DPI。
pub fn top_placement(display: &DisplayGeometry, width_dip: f64, height_dip: f64, center_fraction: f64) -> Result<Placement, String> {
    if !display.scale_factor.is_finite() || display.scale_factor <= 0.0 || display.bounds.width == 0 || display.bounds.height == 0
        || !width_dip.is_finite() || !height_dip.is_finite() || width_dip <= 0.0 || height_dip <= 0.0 || !center_fraction.is_finite() {
        return Err("无效显示器或窗口几何".into());
    }
    let width = (width_dip * display.scale_factor).round().clamp(1.0, display.bounds.width as f64) as u32;
    let height = (height_dip * display.scale_factor).round().clamp(1.0, display.bounds.height as f64) as u32;
    let center = display.bounds.x as f64 + center_fraction.clamp(0.0, 1.0) * display.bounds.width as f64;
    let x = (center - width as f64 / 2.0).round().clamp(display.bounds.x as f64, display.bounds.right() - width as f64);
    Ok(Placement { monitor_id: display.id.clone(), rect: PixelRect { x: x.clamp(i32::MIN as f64, i32::MAX as f64) as i32,
        y: display.bounds.y, width, height }, scale_factor: display.scale_factor })
}

pub fn monitor_at_point(displays: &[DisplayGeometry], point: PixelPoint) -> Option<&DisplayGeometry> {
    displays.iter().find(|display| display.bounds.contains(point))
}

pub fn monitor_for_rect(displays: &[DisplayGeometry], rect: PixelRect) -> Option<&DisplayGeometry> {
    displays.iter().filter(|display| display.bounds.intersection_area(rect) > 0.0)
        .max_by(|left, right| left.bounds.intersection_area(rect).total_cmp(&right.bounds.intersection_area(rect)))
}

/// 普通最大化窗口保留标题栏，应由调用方传入 false，不能仅凭接近屏幕尺寸判断全屏。
pub fn covers_display(window: PixelRect, display: PixelRect, borderless: bool) -> bool {
    borderless && window.width > 0 && window.height > 0
        && window.x as f64 <= display.x as f64 + 2.0 && window.y as f64 <= display.y as f64 + 2.0
        && window.right() >= display.right() - 2.0 && window.bottom() >= display.bottom() - 2.0
}

#[derive(Clone, Debug)]
struct Drag {
    monitor_id: String,
    start_cursor_x: f64,
    start_left: i32,
    started: bool,
}

#[derive(Clone, Debug)]
pub struct WindowPolicy {
    pub follow_mouse: bool,
    pub hide_in_fullscreen: bool,
    current_monitor: Option<String>,
    pinned_monitor: Option<String>,
    centers: HashMap<String, f64>,
    protected_interaction: bool,
    expanded: bool,
    width_dip: f64,
    height_dip: f64,
    drag: Option<Drag>,
}

impl Default for WindowPolicy {
    fn default() -> Self {
        Self { follow_mouse: true, hide_in_fullscreen: false, current_monitor: None, pinned_monitor: None,
            centers: HashMap::new(), protected_interaction: false, expanded: false, width_dip: 261.34, height_dip: 60.77, drag: None }
    }
}

impl WindowPolicy {
    pub fn resize(&mut self, width: f64, height: f64, expanded: bool) -> Result<(), String> {
        if !width.is_finite() || !height.is_finite() || !(180.0..=1200.0).contains(&width) || !(24.0..=1200.0).contains(&height) {
            return Err("无效浮岛尺寸".into());
        }
        self.width_dip = width; self.height_dip = height; self.expanded = expanded;
        if !expanded && !self.protected_interaction { self.pinned_monitor = None; }
        Ok(())
    }

    pub fn set_interaction(&mut self, protected: bool, displays: &[DisplayGeometry], foreground: Option<PixelRect>, cursor: Option<PixelPoint>) {
        if protected && !self.protected_interaction {
            let display = foreground.and_then(|rect| monitor_for_rect(displays, rect))
                .or_else(|| displays.iter().find(|display| display.primary))
                .or_else(|| cursor.and_then(|point| monitor_at_point(displays, point)))
                .or_else(|| displays.first());
            if let Some(display) = display {
                self.pinned_monitor = Some(display.id.clone()); self.current_monitor = Some(display.id.clone());
            }
            self.drag = None;
        }
        self.protected_interaction = protected;
        // 交互结束后继续保持位置，待收起动画完成的 resize(false) 才解除锚定。
    }

    pub fn placement(&mut self, displays: &[DisplayGeometry], cursor: Option<PixelPoint>) -> Result<Placement, String> {
        if displays.is_empty() { return Err("未检测到显示器".into()); }
        let fallback = || displays.iter().find(|display| display.primary).unwrap_or(&displays[0]);
        if self.protected_interaction && self.pinned_monitor.is_none() { self.pinned_monitor = Some(fallback().id.clone()); }
        let selected = if let Some(pin) = &self.pinned_monitor {
            displays.iter().find(|display| &display.id == pin).unwrap_or_else(fallback)
        } else if let Some(drag) = &self.drag {
            displays.iter().find(|display| display.id == drag.monitor_id).unwrap_or_else(fallback)
        } else if self.follow_mouse {
            cursor.and_then(|point| monitor_at_point(displays, point))
                .or_else(|| self.current_monitor.as_ref().and_then(|id| displays.iter().find(|display| &display.id == id)))
                .unwrap_or_else(fallback)
        } else {
            self.current_monitor.as_ref().and_then(|id| displays.iter().find(|display| &display.id == id)).unwrap_or_else(fallback)
        };
        if self.pinned_monitor.is_some() { self.pinned_monitor = Some(selected.id.clone()); }
        if self.drag.as_ref().is_some_and(|drag| drag.monitor_id != selected.id) { self.drag = None; }
        self.current_monitor = Some(selected.id.clone());
        self.centers.retain(|id, _| displays.iter().any(|display| &display.id == id));
        top_placement(selected, self.width_dip, self.height_dip, *self.centers.get(&selected.id).unwrap_or(&0.5))
    }

    pub fn begin_drag(&mut self, placement: &Placement, cursor: PixelPoint) -> Result<(), String> {
        if !cursor.x.is_finite() || !cursor.y.is_finite() { return Err("无效鼠标位置".into()); }
        self.drag = Some(Drag { monitor_id: placement.monitor_id.clone(), start_cursor_x: cursor.x,
            start_left: placement.rect.x, started: false });
        Ok(())
    }

    pub fn update_drag(&mut self, displays: &[DisplayGeometry], cursor: PixelPoint) -> Result<Placement, String> {
        let placement = self.placement(displays, None)?;
        let Some(drag) = &mut self.drag else { return Ok(placement); };
        if !cursor.x.is_finite() { return Err("无效鼠标位置".into()); }
        let display = displays.iter().find(|display| display.id == drag.monitor_id).ok_or("拖动显示器已断开")?;
        let delta = cursor.x - drag.start_cursor_x;
        if delta.abs() > 4.0 * display.scale_factor { drag.started = true; }
        if drag.started {
            let left = (drag.start_left as f64 + delta).clamp(display.bounds.x as f64, display.bounds.right() - placement.rect.width as f64);
            let fraction = (left + placement.rect.width as f64 / 2.0 - display.bounds.x as f64) / display.bounds.width as f64;
            self.centers.insert(display.id.clone(), fraction.clamp(0.0, 1.0));
        }
        self.placement(displays, None)
    }

    pub fn end_drag(&mut self) { self.drag = None; }
    pub fn dragging(&self) -> bool { self.drag.is_some() }
    pub fn pinned(&self) -> bool { self.pinned_monitor.is_some() }
    pub fn should_hide(&self, foreground: Option<(PixelRect, bool)>, display: &DisplayGeometry) -> bool {
        self.hide_in_fullscreen && !self.protected_interaction && !self.dragging()
            && foreground.is_some_and(|(rect, borderless)| covers_display(rect, display.bounds, borderless))
    }
}

#[cfg(feature = "desktop")]
pub use desktop::{WindowController, WindowReport};

#[cfg(feature = "desktop")]
mod desktop {
    use super::*;
    use serde::Serialize;
    use tauri::WebviewWindow;
    #[cfg(not(windows))]
    use tauri::{PhysicalPosition, PhysicalSize};

    #[derive(Clone, Debug, Serialize)]
    #[serde(rename_all = "camelCase")]
    pub struct WindowReport {
        pub monitor_id: String,
        pub scale_factor: f64,
        pub pinned: bool,
        pub dragging: bool,
        pub hidden_for_fullscreen: bool,
    }

    #[derive(Default)]
    pub struct WindowController {
        policy: WindowPolicy,
        last_placement: Option<Placement>,
        hidden_for_fullscreen: bool,
        initialized: bool,
    }

    impl WindowController {
        pub fn resize(&mut self, window: &WebviewWindow, width: f64, height: f64, expanded: bool) -> Result<WindowReport, String> {
            require_main(window)?;
            self.policy.resize(width, height, expanded)?;
            if !expanded { window.set_focusable(false).map_err(|error| error.to_string())?; }
            self.initialized = true;
            self.refresh(window, true)
        }

        pub fn configure(&mut self, window: &WebviewWindow, follow_mouse: bool, hide_in_fullscreen: bool) -> Result<WindowReport, String> {
            require_main(window)?;
            #[cfg(not(windows))]
            if hide_in_fullscreen { return Err("全屏检测仅在 Windows 原生客户端提供".into()); }
            self.policy.follow_mouse = follow_mouse; self.policy.hide_in_fullscreen = hide_in_fullscreen;
            self.refresh(window, false)
        }

        pub fn set_interaction(&mut self, window: &WebviewWindow, protected: bool) -> Result<WindowReport, String> {
            require_main(window)?;
            let displays = displays(window)?;
            let cursor = cursor(window);
            let foreground = foreground_window().map(|(rect, _)| rect);
            self.policy.set_interaction(protected, &displays, foreground, cursor);
            self.refresh(window, protected)
        }

        pub fn poll(&mut self, window: &WebviewWindow) -> Result<WindowReport, String> {
            require_main(window)?;
            if self.policy.dragging() {
                if left_button_down() == Some(false) { return self.end_drag(window); }
                return self.update_drag(window);
            }
            self.refresh(window, false)
        }

        pub fn begin_drag(&mut self, window: &WebviewWindow) -> Result<WindowReport, String> {
            require_main(window)?;
            let displays = displays(window)?;
            let cursor = cursor(window).ok_or("无法读取鼠标位置")?;
            let placement = self.policy.placement(&displays, Some(cursor))?;
            self.policy.begin_drag(&placement, cursor)?;
            self.refresh(window, false)
        }

        pub fn update_drag(&mut self, window: &WebviewWindow) -> Result<WindowReport, String> {
            require_main(window)?;
            let displays = displays(window)?;
            let cursor = cursor(window).ok_or("无法读取鼠标位置")?;
            self.policy.update_drag(&displays, cursor)?;
            self.refresh(window, false)
        }

        pub fn end_drag(&mut self, window: &WebviewWindow) -> Result<WindowReport, String> {
            require_main(window)?;
            if self.policy.dragging() {
                if let Some(cursor) = cursor(window) { self.policy.update_drag(&displays(window)?, cursor)?; }
            }
            self.policy.end_drag();
            self.refresh(window, false)
        }

        fn refresh(&mut self, window: &WebviewWindow, show_requested: bool) -> Result<WindowReport, String> {
            let displays = displays(window)?;
            let placement = self.policy.placement(&displays, cursor(window))?;
            let display = displays.iter().find(|display| display.id == placement.monitor_id).ok_or("显示器已断开")?;
            let hidden = self.policy.should_hide(foreground_window(), display);
            if self.initialized {
                let actual_matches = window.outer_position().ok().zip(window.outer_size().ok()).is_some_and(|(position, size)|
                    position.x == placement.rect.x && position.y == placement.rect.y
                        && size.width == placement.rect.width && size.height == placement.rect.height);
                // WM_DPICHANGED 可能在跨屏定位后应用系统建议矩形，需要核对实际窗口而非仅缓存。
                if self.last_placement.as_ref() != Some(&placement) || !actual_matches {
                    position_without_activation(window, placement.rect)?;
                    self.last_placement = Some(placement.clone());
                }
                if hidden {
                    if window.is_visible().map_err(|error| error.to_string())? { window.hide().map_err(|error| error.to_string())?; }
                } else if show_requested || self.hidden_for_fullscreen {
                    show_without_activation(window)?;
                }
            }
            self.hidden_for_fullscreen = hidden;
            Ok(WindowReport { monitor_id: placement.monitor_id, scale_factor: placement.scale_factor,
                pinned: self.policy.pinned(), dragging: self.policy.dragging(), hidden_for_fullscreen: hidden })
        }
    }

    fn require_main(window: &WebviewWindow) -> Result<(), String> {
        if window.label() == "main" { Ok(()) } else { Err("浮岛窗口策略不能应用到设置窗口".into()) }
    }

    fn displays(window: &WebviewWindow) -> Result<Vec<DisplayGeometry>, String> {
        let available = window.available_monitors().map_err(|error| error.to_string())?;
        let primary = window.primary_monitor().map_err(|error| error.to_string())?;
        let mut names: HashMap<String, usize> = HashMap::new();
        for monitor in &available { if let Some(name) = monitor.name() { *names.entry(name.clone()).or_default() += 1; } }
        Ok(available.iter().map(|monitor| {
            let position = monitor.position(); let size = monitor.size();
            let id = monitor.name().filter(|name| names.get(*name) == Some(&1)).cloned()
                .unwrap_or_else(|| format!("display@{},{}:{}x{}", position.x, position.y, size.width, size.height));
            DisplayGeometry { id, bounds: PixelRect { x: position.x, y: position.y, width: size.width, height: size.height },
                scale_factor: monitor.scale_factor(), primary: primary.as_ref().is_some_and(|primary| primary.position() == position && primary.size() == size) }
        }).collect())
    }

    fn cursor(window: &WebviewWindow) -> Option<PixelPoint> {
        window.cursor_position().ok().map(|position| PixelPoint { x: position.x, y: position.y })
    }

    #[cfg(not(windows))]
    fn foreground_window() -> Option<(PixelRect, bool)> { None }
    #[cfg(not(windows))]
    fn left_button_down() -> Option<bool> { None }

    #[cfg(windows)]
    fn foreground_window() -> Option<(PixelRect, bool)> {
        use windows_sys::Win32::{Foundation::RECT, UI::WindowsAndMessaging::*};
        unsafe {
            let hwnd = GetForegroundWindow();
            if hwnd.is_null() || hwnd == GetDesktopWindow() || hwnd == GetShellWindow() || IsWindowVisible(hwnd) == 0 || IsIconic(hwnd) != 0 { return None; }
            let mut pid = 0; GetWindowThreadProcessId(hwnd, &mut pid);
            if pid == std::process::id() { return None; }
            let mut class = [0u16; 128];
            let length = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32);
            if length > 0 && matches!(String::from_utf16_lossy(&class[..length as usize]).as_str(), "Progman" | "WorkerW" | "Shell_TrayWnd" | "Shell_SecondaryTrayWnd") { return None; }
            let mut rect: RECT = std::mem::zeroed();
            if GetWindowRect(hwnd, &mut rect) == 0 { return None; }
            let width = i64::from(rect.right) - i64::from(rect.left);
            let height = i64::from(rect.bottom) - i64::from(rect.top);
            if width <= 0 || height <= 0 || width > u32::MAX as i64 || height > u32::MAX as i64 { return None; }
            let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
            Some((PixelRect { x: rect.left, y: rect.top, width: width as u32, height: height as u32 },
                style & WS_CAPTION == 0 && IsZoomed(hwnd) == 0))
        }
    }

    #[cfg(windows)]
    fn left_button_down() -> Option<bool> {
        use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
        Some(unsafe { (GetAsyncKeyState(VK_LBUTTON as i32) as u16 & 0x8000) != 0 })
    }

    #[cfg(windows)]
    fn position_without_activation(window: &WebviewWindow, rect: PixelRect) -> Result<(), String> {
        use windows_sys::Win32::UI::WindowsAndMessaging::*;
        let hwnd = window.hwnd().map_err(|error| error.to_string())?.0 as _;
        let width = i32::try_from(rect.width).map_err(|_| "窗口宽度超出系统范围")?;
        let height = i32::try_from(rect.height).map_err(|_| "窗口高度超出系统范围")?;
        let moved = unsafe { SetWindowPos(hwnd, std::ptr::null_mut(), rect.x, rect.y, width, height, SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_NOZORDER) };
        if moved == 0 { Err(format!("浮岛定位失败：{}", std::io::Error::last_os_error())) } else { Ok(()) }
    }

    #[cfg(not(windows))]
    fn position_without_activation(window: &WebviewWindow, rect: PixelRect) -> Result<(), String> {
        window.set_size(PhysicalSize::new(rect.width, rect.height)).map_err(|error| error.to_string())?;
        window.set_position(PhysicalPosition::new(rect.x, rect.y)).map_err(|error| error.to_string())
    }

    #[cfg(windows)]
    fn show_without_activation(window: &WebviewWindow) -> Result<(), String> {
        use windows_sys::Win32::UI::WindowsAndMessaging::{ShowWindow, SW_SHOWNOACTIVATE};
        let hwnd = window.hwnd().map_err(|error| error.to_string())?.0 as _;
        // ShowWindow 返回此前可见状态，不能把 0 当作调用失败。
        unsafe { ShowWindow(hwnd, SW_SHOWNOACTIVATE); }
        Ok(())
    }

    #[cfg(not(windows))]
    fn show_without_activation(window: &WebviewWindow) -> Result<(), String> { window.show().map_err(|error| error.to_string()) }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn displays() -> Vec<DisplayGeometry> {
        vec![DisplayGeometry { id: "left".into(), bounds: PixelRect { x: -2560, y: -200, width: 2560, height: 1440 }, scale_factor: 1.5, primary: false },
            DisplayGeometry { id: "main".into(), bounds: PixelRect { x: 0, y: 0, width: 1920, height: 1080 }, scale_factor: 1.0, primary: true }]
    }
    fn point(x: f64, y: f64) -> PixelPoint { PixelPoint { x, y } }

    #[test]
    fn dip_size_uses_target_dpi_without_scaling_negative_origin() {
        let placement = top_placement(&displays()[0], 380.0, 334.0, 0.5).unwrap();
        assert_eq!(placement.rect, PixelRect { x: -1565, y: -200, width: 570, height: 501 });
        let mut monitor = displays()[0].clone(); monitor.scale_factor = 2.0;
        assert_eq!(top_placement(&monitor, 261.34, 60.77, 0.5).unwrap().rect.width, 523);
    }

    #[test]
    fn oversized_windows_fit_screen_and_invalid_values_fail() {
        let display = displays()[1].clone();
        assert_eq!(top_placement(&display, 9000.0, 9000.0, 1.0).unwrap().rect, display.bounds);
        for size in [f64::NAN, f64::INFINITY, 0.0, -1.0] { assert!(top_placement(&display, size, 20.0, 0.5).is_err()); }
        let mut invalid = display; invalid.scale_factor = f64::NAN;
        assert!(top_placement(&invalid, 380.0, 334.0, 0.5).is_err());
    }

    #[test]
    fn point_boundaries_and_largest_foreground_overlap_are_correct() {
        let displays = displays();
        assert_eq!(monitor_at_point(&displays, point(-1.0, 0.0)).unwrap().id, "left");
        assert_eq!(monitor_at_point(&displays, point(0.0, 0.0)).unwrap().id, "main");
        assert!(monitor_at_point(&displays, point(1920.0, 0.0)).is_none());
        let foreground = PixelRect { x: -50, y: 0, width: 1000, height: 600 };
        assert_eq!(monitor_for_rect(&displays, foreground).unwrap().id, "main");
    }

    #[test]
    fn interaction_pins_foreground_monitor_until_collapse_finishes() {
        let displays = displays(); let mut policy = WindowPolicy::default();
        policy.resize(380.0, 334.0, true).unwrap();
        policy.set_interaction(true, &displays, Some(PixelRect { x: -2000, y: 0, width: 800, height: 600 }), Some(point(1000.0, 100.0)));
        assert_eq!(policy.placement(&displays, Some(point(1000.0, 100.0))).unwrap().monitor_id, "left");
        policy.set_interaction(false, &displays, None, None);
        assert!(policy.pinned());
        policy.resize(261.34, 60.77, false).unwrap();
        assert_eq!(policy.placement(&displays, Some(point(1000.0, 100.0))).unwrap().monitor_id, "main");
    }

    #[test]
    fn interaction_fallback_prefers_primary_over_mouse_monitor() {
        let displays = displays(); let mut policy = WindowPolicy::default();
        policy.set_interaction(true, &displays, None, Some(point(-1000.0, 100.0)));
        assert_eq!(policy.placement(&displays, None).unwrap().monitor_id, "main");
    }

    #[test]
    fn disconnected_pinned_screen_falls_back_and_stays_pinned() {
        let displays = displays(); let mut policy = WindowPolicy::default();
        policy.set_interaction(true, &displays, Some(displays[0].bounds), None);
        assert_eq!(policy.placement(&displays, None).unwrap().monitor_id, "left");
        let remaining = vec![displays[1].clone()];
        assert_eq!(policy.placement(&remaining, None).unwrap().monitor_id, "main");
        assert!(policy.pinned());
        assert_eq!(policy.placement(&displays, Some(point(-1000.0, 0.0))).unwrap().monitor_id, "main");
    }

    #[test]
    fn disconnected_drag_target_cancels_drag_and_falls_back_to_primary() {
        let displays = displays(); let mut policy = WindowPolicy::default();
        let start = policy.placement(&displays, Some(point(-1000.0, 0.0))).unwrap();
        policy.begin_drag(&start, point(-1000.0, 0.0)).unwrap();
        let remaining = vec![displays[1].clone()];
        let placement = policy.update_drag(&remaining, point(100.0, 100.0)).unwrap();
        assert_eq!(placement.monitor_id, "main"); assert!(!policy.dragging());
        assert_eq!(placement.rect.y, 0);
    }

    #[test]
    fn deferred_interaction_pins_primary_when_display_topology_returns() {
        let mut policy = WindowPolicy::default(); policy.set_interaction(true, &[], None, None);
        assert!(policy.placement(&[], None).is_err());
        assert_eq!(policy.placement(&displays(), Some(point(-1000.0, 0.0))).unwrap().monitor_id, "main");
        assert!(policy.pinned());
    }

    #[test]
    fn drag_is_horizontal_dpi_aware_clamped_and_does_not_follow_other_screen() {
        let displays = displays(); let mut policy = WindowPolicy::default();
        let start = policy.placement(&displays, Some(point(-1000.0, 0.0))).unwrap();
        policy.begin_drag(&start, point(-1000.0, 0.0)).unwrap();
        assert_eq!(policy.update_drag(&displays, point(-994.0, 800.0)).unwrap().rect, start.rect);
        let moved = policy.update_drag(&displays, point(2000.0, 800.0)).unwrap();
        assert_eq!(moved.monitor_id, "left"); assert_eq!(moved.rect.y, -200); assert_eq!(moved.rect.right(), 0.0);
        assert_eq!(policy.placement(&displays, Some(point(1000.0, 100.0))).unwrap().monitor_id, "left");
    }

    #[test]
    fn custom_horizontal_center_survives_expansion_and_collapse() {
        let displays = displays(); let mut policy = WindowPolicy::default();
        let start = policy.placement(&displays, Some(point(800.0, 0.0))).unwrap();
        policy.begin_drag(&start, point(800.0, 0.0)).unwrap();
        let dragged = policy.update_drag(&displays, point(1000.0, 0.0)).unwrap(); policy.end_drag();
        let center = dragged.rect.x as f64 + dragged.rect.width as f64 / 2.0;
        policy.resize(380.0, 334.0, true).unwrap();
        let expanded = policy.placement(&displays, None).unwrap();
        assert!((expanded.rect.x as f64 + expanded.rect.width as f64 / 2.0 - center).abs() <= 0.5);
        policy.resize(261.34, 60.77, false).unwrap();
        assert_eq!(policy.placement(&displays, None).unwrap().rect, dragged.rect);
    }

    #[test]
    fn disabled_follow_preserves_monitor_and_missing_cursor_uses_primary() {
        let displays = displays(); let mut policy = WindowPolicy::default(); policy.follow_mouse = false;
        assert_eq!(policy.placement(&displays, Some(point(-1000.0, 0.0))).unwrap().monitor_id, "main");
        policy.follow_mouse = true;
        assert_eq!(policy.placement(&displays, Some(point(-1000.0, 0.0))).unwrap().monitor_id, "left");
        policy.follow_mouse = false;
        assert_eq!(policy.placement(&displays, Some(point(1000.0, 0.0))).unwrap().monitor_id, "left");
    }

    #[test]
    fn fullscreen_is_monitor_specific_not_maximized_and_does_not_hide_interactions() {
        let displays = displays(); let mut policy = WindowPolicy::default(); policy.hide_in_fullscreen = true;
        assert!(!covers_display(displays[0].bounds, displays[0].bounds, false));
        assert!(policy.should_hide(Some((displays[0].bounds, true)), &displays[0]));
        assert!(!policy.should_hide(Some((displays[0].bounds, true)), &displays[1]));
        let work_area = PixelRect { height: displays[1].bounds.height - 48, ..displays[1].bounds };
        assert!(!policy.should_hide(Some((work_area, true)), &displays[1]));
        policy.set_interaction(true, &displays, None, None);
        assert!(!policy.should_hide(Some((displays[1].bounds, true)), &displays[1]));
    }

    #[test]
    fn screen_resize_and_dpi_change_keep_window_inside_monitor() {
        let mut displays = displays(); let mut policy = WindowPolicy::default();
        policy.resize(1200.0, 1200.0, true).unwrap();
        policy.placement(&displays, Some(point(-1000.0, 0.0))).unwrap();
        displays[0].bounds.width = 800; displays[0].bounds.height = 600; displays[0].scale_factor = 2.0;
        let placement = policy.placement(&displays, None).unwrap();
        assert_eq!(placement.rect, displays[0].bounds);
    }

    #[test]
    fn empty_topology_and_invalid_resize_do_not_fabricate_a_monitor() {
        let mut policy = WindowPolicy::default(); assert!(policy.placement(&[], None).is_err());
        assert!(policy.resize(f64::NAN, 60.77, false).is_err());
        assert!(policy.resize(261.34, 0.0, false).is_err());
    }
}
