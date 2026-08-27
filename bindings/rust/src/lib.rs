pub mod raw;

use core::{ffi::c_void, ptr};
use std::{
    alloc::{Layout, alloc, dealloc},
    panic::{AssertUnwindSafe, catch_unwind},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Error(pub i32);

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "tui error {}", self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

pub fn check(result: i32) -> Result<()> {
    if result == raw::TUI_OK_V1 {
        Ok(())
    } else {
        Err(Error(result))
    }
}

unsafe extern "C" fn allocate(_: *mut c_void, size: u64, alignment: u64) -> *mut c_void {
    catch_unwind(AssertUnwindSafe(|| {
        let (Ok(size), Ok(alignment)) = (usize::try_from(size), usize::try_from(alignment)) else {
            return ptr::null_mut();
        };
        let Ok(layout) = Layout::from_size_align(size.max(1), alignment) else {
            return ptr::null_mut();
        };
        unsafe { alloc(layout).cast() }
    }))
    .unwrap_or(ptr::null_mut())
}

unsafe extern "C" fn deallocate(_: *mut c_void, memory: *mut c_void, size: u64, alignment: u64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let (Ok(size), Ok(alignment)) = (usize::try_from(size), usize::try_from(alignment)) else {
            return;
        };
        if let Ok(layout) = Layout::from_size_align(size.max(1), alignment) {
            unsafe { dealloc(memory.cast(), layout) };
        }
    }));
}

pub fn allocator() -> raw::tui_allocator_v1 {
    raw::tui_allocator_v1 {
        context: ptr::null_mut(),
        allocate: Some(allocate),
        deallocate: Some(deallocate),
    }
}

pub fn bytes(value: &[u8]) -> raw::tui_bytes_v1 {
    raw::tui_bytes_v1 {
        ptr: value.as_ptr(),
        len: value.len() as u64,
    }
}

pub fn utf8(value: &str) -> raw::tui_utf8_v1 {
    bytes(value.as_bytes())
}

macro_rules! owned_handle {
    ($name:ident, $raw:ty, $destroy:path) => {
        pub struct $name {
            raw: *mut $raw,
        }
        impl $name {
            pub fn as_ptr(&self) -> *mut $raw {
                self.raw
            }
            /// Takes ownership of a native handle.
            ///
            /// # Safety
            ///
            /// `raw` must be a valid, uniquely owned handle of the matching type.
            pub unsafe fn from_raw(raw: *mut $raw) -> Self {
                Self { raw }
            }
        }
        impl Drop for $name {
            fn drop(&mut self) {
                if !self.raw.is_null() {
                    unsafe { $destroy(self.raw) };
                    self.raw = ptr::null_mut();
                }
            }
        }
    };
}

owned_handle!(Renderer, raw::tui_renderer_v1, raw::tui_renderer_destroy_v1);
owned_handle!(
    TextInput,
    raw::tui_text_input_v1,
    raw::tui_text_input_destroy_v1
);
owned_handle!(
    TextArea,
    raw::tui_text_area_v1,
    raw::tui_text_area_destroy_v1
);
owned_handle!(
    LineChart,
    raw::tui_line_chart_v1,
    raw::tui_line_chart_destroy_v1
);
owned_handle!(
    EventQueue,
    raw::tui_event_queue_v1,
    raw::tui_event_queue_destroy_v1
);
owned_handle!(Parser, raw::tui_parser_v1, raw::tui_parser_destroy_v1);

impl Renderer {
    pub fn new(size: raw::tui_size_v1) -> Result<Self> {
        let allocator = allocator();
        let mut raw = ptr::null_mut();
        check(unsafe { raw::tui_renderer_create_v1(&allocator, size, ptr::null(), &mut raw) })?;
        Ok(Self { raw })
    }
}

impl TextInput {
    pub fn new(capacity: u64, initial: &str) -> Result<Self> {
        let allocator = allocator();
        let mut raw = ptr::null_mut();
        check(unsafe {
            raw::tui_text_input_create_v1(&allocator, capacity, utf8(initial), &mut raw)
        })?;
        Ok(Self { raw })
    }
}

impl TextArea {
    pub fn new(capacity: u64, initial: &str) -> Result<Self> {
        let allocator = allocator();
        let mut raw = ptr::null_mut();
        check(unsafe {
            raw::tui_text_area_create_v1(&allocator, capacity, utf8(initial), &mut raw)
        })?;
        Ok(Self { raw })
    }
}

impl LineChart {
    pub fn new(samples: u64, cells: u64) -> Result<Self> {
        let allocator = allocator();
        let mut raw = ptr::null_mut();
        check(unsafe { raw::tui_line_chart_create_v1(&allocator, samples, cells, &mut raw) })?;
        Ok(Self { raw })
    }
}

impl EventQueue {
    pub fn new(capacity: u64) -> Result<Self> {
        let allocator = allocator();
        let mut raw = ptr::null_mut();
        check(unsafe { raw::tui_event_queue_create_v1(&allocator, capacity, &mut raw) })?;
        Ok(Self { raw })
    }
}

impl Parser {
    pub fn new() -> Result<Self> {
        let allocator = allocator();
        let mut raw = ptr::null_mut();
        check(unsafe { raw::tui_parser_create_v1(&allocator, &mut raw) })?;
        Ok(Self { raw })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_and_owned_handles() {
        let version = unsafe { raw::tui_abi_version_v1() };
        assert_eq!((version.major, version.minor, version.patch), (1, 0, 0));
        let _renderer = Renderer::new(raw::tui_size_v1 {
            width: 8,
            height: 2,
        })
        .unwrap();
        let _input = TextInput::new(32, "ready").unwrap();
        let _area = TextArea::new(64, "one\ntwo").unwrap();
        let _chart = LineChart::new(8, 8).unwrap();
        let _queue = EventQueue::new(4).unwrap();
        let _parser = Parser::new().unwrap();
    }
}
