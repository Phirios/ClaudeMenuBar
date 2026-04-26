use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tiny_skia::*;

// ── Colors ───────────────────────────────────────────────────────────────────

fn percent_color(pct: i32) -> (u8, u8, u8) {
    match pct {
        85.. => (220, 50, 50),
        70.. => (230, 130, 40),
        55.. => (200, 180, 40),
        _ => (60, 180, 80),
    }
}

// ── Icon rendering ───────────────────────────────────────────────────────────

fn arc_path(cx: f32, cy: f32, r: f32, start: f32, sweep: f32) -> Option<Path> {
    if sweep.abs() < 0.001 {
        return None;
    }
    const STEPS: usize = 64;
    let mut pb = PathBuilder::new();
    for i in 0..=STEPS {
        let a = start + (i as f32 / STEPS as f32) * sweep;
        let (x, y) = (cx + r * a.cos(), cy + r * a.sin());
        if i == 0 {
            pb.move_to(x, y);
        } else {
            pb.line_to(x, y);
        }
    }
    pb.finish()
}

/// Returns ARGB data (network byte order) for the ksni StatusNotifierItem icon.
fn render_icon(session_pct: i32, weekly_pct: i32, blocked: bool, pulse: f32) -> Vec<u8> {
    const S: u32 = 64;
    const CX: f32 = 32.0;
    const CY: f32 = 32.0;
    const OUTER_R: f32 = 27.5;
    const RING_W: f32 = 4.5;
    const INNER_R: f32 = OUTER_R - RING_W - 2.5;

    let mut pm = Pixmap::new(S, S).unwrap();
    let mut paint = Paint::default();
    paint.anti_alias = true;
    let mut stroke = Stroke::default();
    stroke.width = RING_W;
    stroke.line_cap = LineCap::Round;

    // Background ring
    if let Some(p) = arc_path(CX, CY, OUTER_R - RING_W / 2.0, 0.0, std::f32::consts::TAU) {
        paint.set_color_rgba8(150, 150, 150, 65);
        pm.stroke_path(&p, &paint, &stroke, Transform::identity(), None);
    }

    // Session arc: top (−π/2) → clockwise
    if session_pct > 0 {
        let (r, g, b) = if blocked { (220, 50, 50) } else { percent_color(session_pct) };
        let sweep = (session_pct.min(100) as f32 / 100.0) * std::f32::consts::TAU;
        if let Some(p) = arc_path(CX, CY, OUTER_R - RING_W / 2.0, -std::f32::consts::FRAC_PI_2, sweep) {
            paint.set_color_rgba8(r, g, b, 255);
            pm.stroke_path(&p, &paint, &stroke, Transform::identity(), None);
        }
    }

    // Inner circle background
    let inner_circle = PathBuilder::from_circle(CX, CY, INNER_R).unwrap();
    paint.set_color_rgba8(150, 150, 150, 45);
    pm.fill_path(&inner_circle, &paint, FillRule::Winding, Transform::identity(), None);

    // Weekly fill: bottom → top, clipped to inner circle
    if weekly_pct > 0 {
        let (r, g, b) = if blocked { (220, 50, 50) } else { percent_color(weekly_pct) };
        let fill_h = INNER_R * 2.0 * (weekly_pct.min(100) as f32 / 100.0);
        let fill_top = CY + INNER_R - fill_h;

        if let Some(rect) = Rect::from_xywh(CX - INNER_R, fill_top, INNER_R * 2.0, fill_h + 0.5) {
            let fill_path = PathBuilder::from_rect(rect);
            let mut clip = ClipMask::new();
            if clip
                .set_path(S, S, &inner_circle, FillRule::Winding, true)
                .is_some()
            {
                paint.set_color_rgba8(r, g, b, 195);
                pm.fill_path(&fill_path, &paint, FillRule::Winding, Transform::identity(), Some(&clip));
            }
        }
    }

    // Pulsing live dot (top-right corner)
    if pulse > 0.01 {
        if let Some(dot) = PathBuilder::from_circle(S as f32 - 7.0, 7.0, 4.0) {
            paint.set_color_rgba8(0xD9, 0x77, 0x57, (pulse * 255.0) as u8);
            pm.fill_path(&dot, &paint, FillRule::Winding, Transform::identity(), None);
        }
    }

    // tiny-skia premultiplied RGBA → straight ARGB (network byte order for D-Bus)
    pm.data()
        .chunks(4)
        .flat_map(|p| {
            let a = p[3];
            if a == 0 {
                return [0u8, 0, 0, 0];
            }
            let af = a as f32 / 255.0;
            [
                a,
                (p[0] as f32 / af).min(255.0) as u8,
                (p[1] as f32 / af).min(255.0) as u8,
                (p[2] as f32 / af).min(255.0) as u8,
            ]
        })
        .collect()
}

// ── Usage data ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone)]
struct UsageData {
    five_h_util: f32,
    five_h_reset: i64,
    seven_d_util: f32,
    seven_d_reset: i64,
    overage_util: f32,
    claim: String,
    status: String,
    fetched_at: i64,
}

impl UsageData {
    fn five_h_pct(&self) -> i32 { (self.five_h_util * 100.0) as i32 }
    fn seven_d_pct(&self) -> i32 { (self.seven_d_util * 100.0) as i32 }
    fn overage_pct(&self) -> i32 { (self.overage_util * 100.0) as i32 }
}

fn now_secs() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn get_token() -> Option<String> {
    let home = std::env::var("HOME").ok()?;
    let path = PathBuf::from(home).join(".claude/claude-menubar-token");
    let t = std::fs::read_to_string(path).ok()?.trim().to_owned();
    if t.is_empty() { None } else { Some(t) }
}

fn hdr_f32(resp: &ureq::Response, key: &str) -> Option<f32> {
    resp.header(key)?.parse().ok()
}

fn hdr_i64(resp: &ureq::Response, key: &str) -> Option<i64> {
    resp.header(key)?.parse().ok()
}

fn parse_headers(resp: &ureq::Response) -> Option<UsageData> {
    let now = now_secs();
    Some(UsageData {
        five_h_util: hdr_f32(resp, "anthropic-ratelimit-unified-5h-utilization")?,
        five_h_reset: hdr_i64(resp, "anthropic-ratelimit-unified-5h-reset").unwrap_or(now),
        seven_d_util: hdr_f32(resp, "anthropic-ratelimit-unified-7d-utilization")?,
        seven_d_reset: hdr_i64(resp, "anthropic-ratelimit-unified-7d-reset").unwrap_or(now),
        overage_util: hdr_f32(resp, "anthropic-ratelimit-unified-overage-utilization").unwrap_or(0.0),
        claim: resp
            .header("anthropic-ratelimit-unified-representative-claim")
            .unwrap_or("")
            .into(),
        status: resp
            .header("anthropic-ratelimit-unified-status")
            .unwrap_or("unknown")
            .into(),
        fetched_at: now,
    })
}

fn do_fetch(token: &str) -> Result<UsageData, String> {
    let body = serde_json::json!({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "."}]
    });

    let result = ureq::post("https://api.anthropic.com/v1/messages")
        .set("x-api-key", token)
        .set("anthropic-version", "2023-06-01")
        .set("content-type", "application/json")
        .send_json(body);

    let resp = match result {
        Ok(r) => r,
        Err(ureq::Error::Status(401, _)) => {
            return Err("Auth expired — run: claude auth login".into())
        }
        Err(ureq::Error::Status(_, r)) => r,
        Err(e) => return Err(e.to_string()),
    };

    parse_headers(&resp).ok_or_else(|| "Rate limit headers not found".into())
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn bar(pct: i32) -> String {
    let n = pct.clamp(0, 100) / 5;
    format!("[{}{}]", "█".repeat(n as usize), "░".repeat((20 - n) as usize))
}

fn rel_time(ts: i64) -> String {
    let diff = ts - now_secs();
    if diff <= 0 {
        return "now".into();
    }
    let (h, m) = (diff / 3600, (diff % 3600) / 60);
    if h > 0 {
        format!("in {}h {}m", h, m)
    } else {
        format!("in {}m", m)
    }
}

fn is_claude_running() -> bool {
    std::process::Command::new("pgrep")
        .args(["-f", "claude"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

// ── Tray ─────────────────────────────────────────────────────────────────────

struct ClaudeTray {
    usage: Option<UsageData>,
    error: Option<String>,
    is_live: bool,
    pulse: f32,
    pulse_dir: f32,
    refresh_tx: mpsc::SyncSender<()>,
}

impl ksni::Tray for ClaudeTray {
    fn id(&self) -> String {
        "claude-menubar".into()
    }

    fn category(&self) -> ksni::Category {
        ksni::Category::ApplicationStatus
    }

    fn title(&self) -> String {
        match &self.usage {
            Some(u) => format!("Claude {}%/{}%", u.five_h_pct(), u.seven_d_pct()),
            None => "ClaudeMenuBar".into(),
        }
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        let (s5, s7, blocked) = match &self.usage {
            Some(u) => (u.five_h_pct(), u.seven_d_pct(), u.status != "allowed"),
            None => (0, 0, false),
        };
        let pulse = if self.is_live { self.pulse } else { 0.0 };
        vec![ksni::Icon {
            width: 64,
            height: 64,
            data: render_icon(s5, s7, blocked, pulse),
        }]
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::StandardItem;

        let disabled = |label: String| -> ksni::MenuItem<Self> {
            StandardItem {
                label,
                enabled: false,
                ..Default::default()
            }
            .into()
        };

        let mut items: Vec<ksni::MenuItem<Self>> = vec![];

        items.push(disabled(if self.is_live {
            "● Claude is running".into()
        } else {
            "○ Claude is idle".into()
        }));
        items.push(ksni::MenuItem::Separator);

        match &self.usage {
            Some(u) => {
                items.push(disabled(if u.status == "allowed" {
                    "✅ Allowed".into()
                } else {
                    "🔴 Blocked".into()
                }));
                items.push(ksni::MenuItem::Separator);

                let a5 = if u.claim == "five_hour" { " ◀" } else { "" };
                items.push(disabled(format!(
                    "5h  {} {}%{}",
                    bar(u.five_h_pct()),
                    u.five_h_pct(),
                    a5
                )));
                items.push(disabled(format!("    Reset: {}", rel_time(u.five_h_reset))));
                items.push(ksni::MenuItem::Separator);

                let a7 = if u.claim == "seven_day" { " ◀" } else { "" };
                items.push(disabled(format!(
                    "7d  {} {}%{}",
                    bar(u.seven_d_pct()),
                    u.seven_d_pct(),
                    a7
                )));
                items.push(disabled(format!("    Reset: {}", rel_time(u.seven_d_reset))));

                if u.overage_pct() > 0 {
                    items.push(ksni::MenuItem::Separator);
                    items.push(disabled(format!(
                        "Ovg {} {}%",
                        bar(u.overage_pct()),
                        u.overage_pct()
                    )));
                }

                items.push(ksni::MenuItem::Separator);
                let ago = now_secs() - u.fetched_at;
                items.push(disabled(if ago < 60 {
                    format!("Updated: {}s ago", ago)
                } else {
                    format!("Updated: {}m ago", ago / 60)
                }));
            }
            None => {
                items.push(disabled(match &self.error {
                    Some(e) => format!("⚠ {}", e),
                    None => "Fetching...".into(),
                }));
            }
        }

        items.push(ksni::MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Refresh Now".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = this.refresh_tx.try_send(());
                }),
                ..Default::default()
            }
            .into(),
        );
        items.push(ksni::MenuItem::Separator);
        items.push(
            StandardItem {
                label: "Quit".into(),
                activate: Box::new(|_| std::process::exit(0)),
                ..Default::default()
            }
            .into(),
        );

        items
    }
}

// ── Main ─────────────────────────────────────────────────────────────────────

fn fetch_and_update(handle: &ksni::Handle<ClaudeTray>) {
    let result = match get_token() {
        Some(t) => do_fetch(&t),
        None => Err("Token not found. Run: claude auth login".into()),
    };
    handle.update(move |t| match result {
        Ok(u) => {
            t.usage = Some(u);
            t.error = None;
        }
        Err(e) => {
            t.error = Some(e);
        }
    });
}

fn main() {
    let (refresh_tx, refresh_rx) = mpsc::sync_channel::<()>(1);

    let service = ksni::TrayService::new(ClaudeTray {
        usage: None,
        error: None,
        is_live: false,
        pulse: 1.0,
        pulse_dir: -1.0,
        refresh_tx,
    });
    let handle = service.handle();
    service.spawn();

    let is_live_flag = Arc::new(AtomicBool::new(false));

    // Initial fetch
    {
        let h = handle.clone();
        thread::spawn(move || fetch_and_update(&h));
    }

    // Refresh loop: fires on timer OR manual "Refresh Now"
    {
        let h = handle.clone();
        let live_flag = Arc::clone(&is_live_flag);
        thread::spawn(move || loop {
            let secs = if live_flag.load(Ordering::Relaxed) { 60 } else { 300 };
            match refresh_rx.recv_timeout(Duration::from_secs(secs)) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Timeout) => fetch_and_update(&h),
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        });
    }

    // Process check loop: detect active claude sessions
    {
        let h = handle.clone();
        let live_flag = Arc::clone(&is_live_flag);
        thread::spawn(move || loop {
            let live = is_claude_running();
            live_flag.store(live, Ordering::Relaxed);
            h.update(move |t| {
                if !live && t.is_live {
                    t.pulse = 1.0;
                }
                t.is_live = live;
            });
            thread::sleep(Duration::from_secs(3));
        });
    }

    // Pulse animation loop (~15 fps while live)
    {
        let h = handle.clone();
        thread::spawn(move || loop {
            h.update(|t| {
                if t.is_live {
                    t.pulse += t.pulse_dir * 0.04;
                    if t.pulse <= 0.3 {
                        t.pulse = 0.3;
                        t.pulse_dir = 1.0;
                    } else if t.pulse >= 1.0 {
                        t.pulse = 1.0;
                        t.pulse_dir = -1.0;
                    }
                }
            });
            thread::sleep(Duration::from_millis(70));
        });
    }

    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}
