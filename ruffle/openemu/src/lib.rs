use std::any::Any;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::{Arc, Mutex};

use ruffle_core::backend::audio::{
    AudioBackend, AudioMixer, AudioMixerProxy, DecodeError, RegisterError,
    SoundHandle, SoundInstanceHandle, SoundStreamInfo, SoundTransform,
};
use ruffle_core::backend::navigator::NullNavigatorBackend;
use ruffle_core::backend::storage::MemoryStorageBackend;
use ruffle_core::backend::ui::NullUiBackend;
use ruffle_core::events::{
    KeyCode, KeyDescriptor, KeyLocation, LogicalKey, MouseButton, NamedKey,
    PhysicalKey, PlayerEvent,
};
use ruffle_core::tag_utils::SwfMovie;
use ruffle_core::{Player, PlayerBuilder};
use ruffle_render_wgpu::backend::WgpuRenderBackend;
use ruffle_render_wgpu::target::TextureTarget;
use ruffle_video_software::backend::SoftwareVideoBackend;

// Re-export swf crate so the impl_audio_mixer_backend macro can use `swf::` paths
use ruffle_core::swf;

// Re-export the macro for the audio backend
use ruffle_core::impl_audio_mixer_backend;

/// Custom audio backend that stores audio in a mixer we can pull from.
struct OpenEmuAudioBackend {
    mixer: AudioMixer,
}

impl OpenEmuAudioBackend {
    fn new(num_channels: u8, sample_rate: u32) -> Self {
        Self {
            mixer: AudioMixer::new(num_channels, sample_rate),
        }
    }

    fn proxy(&self) -> AudioMixerProxy {
        self.mixer.proxy()
    }
}

impl AudioBackend for OpenEmuAudioBackend {
    impl_audio_mixer_backend!(mixer);

    fn play(&mut self) {}
    fn pause(&mut self) {}
}

/// Opaque context holding the Ruffle player and associated state.
struct RuffleContext {
    player: Arc<Mutex<Player>>,
    audio_proxy: AudioMixerProxy,
    pixel_buffer: Vec<u8>,
    width: u32,
    height: u32,
    swf_path: Option<String>,
    sample_rate: u32,
}

/// Create a new Ruffle context with offscreen rendering.
///
/// # Safety
/// Returns an opaque pointer. Must be freed with `ruffle_destroy`.
#[no_mangle]
pub unsafe extern "C" fn ruffle_create(
    width: u32,
    height: u32,
    sample_rate: u32,
) -> *mut RuffleContext {
    // Initialize tracing (only once, ignore errors on subsequent calls)
    let _ = tracing_subscriber::fmt()
        .with_env_filter("warn")
        .try_init();

    // Create audio backend and grab a proxy before moving it into the player
    let audio_backend = OpenEmuAudioBackend::new(2, sample_rate);
    let audio_proxy = audio_backend.proxy();

    // Create offscreen wgpu renderer
    let renderer = match WgpuRenderBackend::<TextureTarget>::for_offscreen(
        (width, height),
        wgpu::Backends::METAL,
        wgpu::PowerPreference::HighPerformance,
    ) {
        Ok(r) => r,
        Err(e) => {
            tracing::error!("Failed to create wgpu renderer: {}", e);
            return std::ptr::null_mut();
        }
    };

    let player = PlayerBuilder::new()
        .with_boxed_audio(Box::new(audio_backend))
        .with_boxed_renderer(Box::new(renderer))
        .with_navigator(NullNavigatorBackend::new())
        .with_storage(Box::new(MemoryStorageBackend::new()))
        .with_ui(NullUiBackend::new())
        .with_video(SoftwareVideoBackend::new())
        .with_autoplay(true)
        .build();

    let ctx = Box::new(RuffleContext {
        player,
        audio_proxy,
        pixel_buffer: vec![0u8; (width * height * 4) as usize],
        width,
        height,
        swf_path: None,
        sample_rate,
    });

    Box::into_raw(ctx)
}

/// Load a SWF file. Returns true on success.
///
/// # Safety
/// `handle` must be a valid pointer from `ruffle_create`.
/// `path` must be a valid null-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn ruffle_load(handle: *mut RuffleContext, path: *const c_char) -> bool {
    if handle.is_null() || path.is_null() {
        return false;
    }

    let ctx = &mut *handle;
    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(s) => s,
        Err(_) => return false,
    };

    ctx.swf_path = Some(path_str.to_string());

    let swf_data = match std::fs::read(path_str) {
        Ok(data) => data,
        Err(e) => {
            tracing::error!("Failed to read SWF file: {}", e);
            return false;
        }
    };

    let swf_url = url::Url::from_file_path(path_str).unwrap_or_else(|_| {
        url::Url::parse(&format!("file://{}", path_str)).unwrap()
    });

    let movie = match SwfMovie::from_data(&swf_data, swf_url.to_string(), None) {
        Ok(m) => m,
        Err(e) => {
            tracing::error!("Failed to parse SWF: {}", e);
            return false;
        }
    };

    // Update viewport to match movie dimensions if needed
    let movie_width = movie.width().to_pixels() as u32;
    let movie_height = movie.height().to_pixels() as u32;

    let mut player = ctx.player.lock().unwrap();

    if movie_width > 0 && movie_height > 0 {
        ctx.width = movie_width;
        ctx.height = movie_height;
        ctx.pixel_buffer = vec![0u8; (movie_width * movie_height * 4) as usize];
        player.set_viewport_dimensions(ruffle_render::backend::ViewportDimensions {
            width: movie_width,
            height: movie_height,
            scale_factor: 1.0,
        });
    }

    player.mutate_with_update_context(|context| {
        context.set_root_movie(movie);
    });
    player.set_is_playing(true);

    true
}

/// Advance the player by `dt_micros` microseconds.
///
/// # Safety
/// `handle` must be a valid pointer from `ruffle_create`.
#[no_mangle]
pub unsafe extern "C" fn ruffle_tick(handle: *mut RuffleContext, dt_micros: u64) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let dt = ruffle_core::FloatDuration::from_millis(dt_micros as f64 / 1000.0);
    let mut player = ctx.player.lock().unwrap();
    player.tick(dt);
}

/// Render the current frame and copy RGBA pixels into `pixel_buf`.
///
/// # Safety
/// `handle` must be valid. `pixel_buf` must point to at least `width * height * 4` bytes.
#[no_mangle]
pub unsafe extern "C" fn ruffle_render(
    handle: *mut RuffleContext,
    pixel_buf: *mut u8,
    width: u32,
    height: u32,
) {
    if handle.is_null() || pixel_buf.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let mut player = ctx.player.lock().unwrap();

    player.render();

    // Capture the rendered frame
    let renderer = player.renderer_mut();
    if let Some(renderer) =
        <dyn Any>::downcast_mut::<WgpuRenderBackend<TextureTarget>>(renderer)
    {
        if let Some(image) = renderer.capture_frame() {
            let src: &[u8] = image.as_raw();
            let copy_len = std::cmp::min(src.len(), (width * height * 4) as usize);
            std::ptr::copy_nonoverlapping(src.as_ptr(), pixel_buf, copy_len);
        }
    }
}

/// Mix audio samples into the provided buffer.
/// `buffer` should hold `num_frames * 2` int16 samples (stereo).
/// Returns the number of frames actually written.
///
/// # Safety
/// `handle` must be valid. `buffer` must be large enough.
#[no_mangle]
pub unsafe extern "C" fn ruffle_get_audio(
    handle: *mut RuffleContext,
    buffer: *mut i16,
    num_frames: i32,
) -> i32 {
    if handle.is_null() || buffer.is_null() || num_frames <= 0 {
        return 0;
    }
    let ctx = &mut *handle;
    let total_samples = (num_frames * 2) as usize; // stereo
    let mut output = vec![0i16; total_samples];
    ctx.audio_proxy.mix(&mut output);
    std::ptr::copy_nonoverlapping(output.as_ptr(), buffer, total_samples);
    num_frames
}

/// Send a key down event to the player.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ruffle_key_down(handle: *mut RuffleContext, key_code: u32) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let mut player = ctx.player.lock().unwrap();
    if let Some(event) = make_key_event(key_code, true) {
        player.handle_event(event);
    }
}

/// Send a key up event to the player.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ruffle_key_up(handle: *mut RuffleContext, key_code: u32) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let mut player = ctx.player.lock().unwrap();
    if let Some(event) = make_key_event(key_code, false) {
        player.handle_event(event);
    }
}

/// Send a mouse move event to the player.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ruffle_mouse_move(handle: *mut RuffleContext, x: f64, y: f64) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let mut player = ctx.player.lock().unwrap();
    player.handle_event(PlayerEvent::MouseMove { x, y });
}

/// Send a mouse button down event.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ruffle_mouse_down(handle: *mut RuffleContext, x: f64, y: f64, button: i32) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let btn = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        _ => MouseButton::Unknown,
    };
    let mut player = ctx.player.lock().unwrap();
    player.handle_event(PlayerEvent::MouseDown { x, y, button: btn, index: None });
}

/// Send a mouse button up event.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ruffle_mouse_up(handle: *mut RuffleContext, x: f64, y: f64, button: i32) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    let btn = match button {
        0 => MouseButton::Left,
        1 => MouseButton::Right,
        2 => MouseButton::Middle,
        _ => MouseButton::Unknown,
    };
    let mut player = ctx.player.lock().unwrap();
    player.handle_event(PlayerEvent::MouseUp { x, y, button: btn });
}

/// Get the SWF movie width in pixels.
#[no_mangle]
pub unsafe extern "C" fn ruffle_get_movie_width(handle: *mut RuffleContext) -> u32 {
    if handle.is_null() {
        return 0;
    }
    (*handle).width
}

/// Get the SWF movie height in pixels.
#[no_mangle]
pub unsafe extern "C" fn ruffle_get_movie_height(handle: *mut RuffleContext) -> u32 {
    if handle.is_null() {
        return 0;
    }
    (*handle).height
}

/// Get the SWF frame rate.
#[no_mangle]
pub unsafe extern "C" fn ruffle_get_frame_rate(handle: *mut RuffleContext) -> f64 {
    if handle.is_null() {
        return 30.0;
    }
    let ctx = &*handle;
    let player = ctx.player.lock().unwrap();
    player.frame_rate()
}

/// Reset the player by reloading the SWF.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn ruffle_reset(handle: *mut RuffleContext) {
    if handle.is_null() {
        return;
    }
    let ctx = &mut *handle;
    if let Some(ref path) = ctx.swf_path.clone() {
        if let Ok(swf_data) = std::fs::read(path) {
            let swf_url = url::Url::from_file_path(path).unwrap_or_else(|_| {
                url::Url::parse(&format!("file://{}", path)).unwrap()
            });
            if let Ok(movie) = SwfMovie::from_data(&swf_data, swf_url.to_string(), None) {
                let mut player = ctx.player.lock().unwrap();
                player.mutate_with_update_context(|context| {
                    context.set_root_movie(movie);
                });
                player.set_is_playing(true);
            }
        }
    }
}

/// Destroy the Ruffle context and free all resources.
///
/// # Safety
/// `handle` must be a valid pointer from `ruffle_create`, or null (no-op).
#[no_mangle]
pub unsafe extern "C" fn ruffle_destroy(handle: *mut RuffleContext) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

// -- Key code mapping --

/// Map OEFlashButton enum values to a (PhysicalKey, LogicalKey, KeyCode) tuple.
/// The key codes here correspond to the OEFlashButton enum defined in
/// OEFlashSystemResponderClient.h.
fn make_key_event(key_code: u32, is_down: bool) -> Option<PlayerEvent> {
    let (physical, logical, flash_key) = match key_code {
        // Arrow keys
        0 => (PhysicalKey::ArrowUp, LogicalKey::Named(NamedKey::ArrowUp), KeyCode::UP),
        1 => (PhysicalKey::ArrowDown, LogicalKey::Named(NamedKey::ArrowDown), KeyCode::DOWN),
        2 => (PhysicalKey::ArrowLeft, LogicalKey::Named(NamedKey::ArrowLeft), KeyCode::LEFT),
        3 => (PhysicalKey::ArrowRight, LogicalKey::Named(NamedKey::ArrowRight), KeyCode::RIGHT),
        // Special keys
        4 => (PhysicalKey::Space, LogicalKey::Character(' '), KeyCode::SPACE),
        5 => (PhysicalKey::Enter, LogicalKey::Named(NamedKey::Enter), KeyCode::ENTER),
        6 => (PhysicalKey::Escape, LogicalKey::Named(NamedKey::Escape), KeyCode::ESCAPE),
        7 => (PhysicalKey::ShiftLeft, LogicalKey::Named(NamedKey::Shift), KeyCode::SHIFT),
        8 => (PhysicalKey::ControlLeft, LogicalKey::Named(NamedKey::Control), KeyCode::CONTROL),
        9 => (PhysicalKey::Tab, LogicalKey::Named(NamedKey::Tab), KeyCode::TAB),
        // Letters A-Z (10..=35)
        10 => (PhysicalKey::KeyA, LogicalKey::Character('a'), KeyCode::A),
        11 => (PhysicalKey::KeyB, LogicalKey::Character('b'), KeyCode::B),
        12 => (PhysicalKey::KeyC, LogicalKey::Character('c'), KeyCode::C),
        13 => (PhysicalKey::KeyD, LogicalKey::Character('d'), KeyCode::D),
        14 => (PhysicalKey::KeyE, LogicalKey::Character('e'), KeyCode::E),
        15 => (PhysicalKey::KeyF, LogicalKey::Character('f'), KeyCode::F),
        16 => (PhysicalKey::KeyG, LogicalKey::Character('g'), KeyCode::G),
        17 => (PhysicalKey::KeyH, LogicalKey::Character('h'), KeyCode::H),
        18 => (PhysicalKey::KeyI, LogicalKey::Character('i'), KeyCode::I),
        19 => (PhysicalKey::KeyJ, LogicalKey::Character('j'), KeyCode::J),
        20 => (PhysicalKey::KeyK, LogicalKey::Character('k'), KeyCode::K),
        21 => (PhysicalKey::KeyL, LogicalKey::Character('l'), KeyCode::L),
        22 => (PhysicalKey::KeyM, LogicalKey::Character('m'), KeyCode::M),
        23 => (PhysicalKey::KeyN, LogicalKey::Character('n'), KeyCode::N),
        24 => (PhysicalKey::KeyO, LogicalKey::Character('o'), KeyCode::O),
        25 => (PhysicalKey::KeyP, LogicalKey::Character('p'), KeyCode::P),
        26 => (PhysicalKey::KeyQ, LogicalKey::Character('q'), KeyCode::Q),
        27 => (PhysicalKey::KeyR, LogicalKey::Character('r'), KeyCode::R),
        28 => (PhysicalKey::KeyS, LogicalKey::Character('s'), KeyCode::S),
        29 => (PhysicalKey::KeyT, LogicalKey::Character('t'), KeyCode::T),
        30 => (PhysicalKey::KeyU, LogicalKey::Character('u'), KeyCode::U),
        31 => (PhysicalKey::KeyV, LogicalKey::Character('v'), KeyCode::V),
        32 => (PhysicalKey::KeyW, LogicalKey::Character('w'), KeyCode::W),
        33 => (PhysicalKey::KeyX, LogicalKey::Character('x'), KeyCode::X),
        34 => (PhysicalKey::KeyY, LogicalKey::Character('y'), KeyCode::Y),
        35 => (PhysicalKey::KeyZ, LogicalKey::Character('z'), KeyCode::Z),
        // Numbers 0-9 (36..=45)
        36 => (PhysicalKey::Digit0, LogicalKey::Character('0'), KeyCode::NUMBER_0),
        37 => (PhysicalKey::Digit1, LogicalKey::Character('1'), KeyCode::NUMBER_1),
        38 => (PhysicalKey::Digit2, LogicalKey::Character('2'), KeyCode::NUMBER_2),
        39 => (PhysicalKey::Digit3, LogicalKey::Character('3'), KeyCode::NUMBER_3),
        40 => (PhysicalKey::Digit4, LogicalKey::Character('4'), KeyCode::NUMBER_4),
        41 => (PhysicalKey::Digit5, LogicalKey::Character('5'), KeyCode::NUMBER_5),
        42 => (PhysicalKey::Digit6, LogicalKey::Character('6'), KeyCode::NUMBER_6),
        43 => (PhysicalKey::Digit7, LogicalKey::Character('7'), KeyCode::NUMBER_7),
        44 => (PhysicalKey::Digit8, LogicalKey::Character('8'), KeyCode::NUMBER_8),
        45 => (PhysicalKey::Digit9, LogicalKey::Character('9'), KeyCode::NUMBER_9),
        _ => return None,
    };

    let _ = flash_key; // Used by Ruffle's internal AVM key code mapping

    let key_descriptor = KeyDescriptor {
        physical_key: physical,
        logical_key: logical,
        key_location: KeyLocation::Standard,
    };

    Some(if is_down {
        PlayerEvent::KeyDown { key: key_descriptor }
    } else {
        PlayerEvent::KeyUp { key: key_descriptor }
    })
}
