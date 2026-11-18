//! Private in-process producer boundary. The shell links the archive, not this checkout.
use serde::Deserialize;
use std::{
    ffi::{CStr, c_char},
    path::PathBuf,
};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    input: PathBuf,
    keys: PathBuf,
    work: PathBuf,
    output: PathBuf,
    #[serde(default)]
    updates: Vec<PathBuf>,
    #[serde(default)]
    dlc: Vec<PathBuf>,
    #[serde(rename = "titleID")]
    title_id: Option<String>,
    base_package: Option<PathBuf>,
    #[serde(rename = "runtimeABI")]
    runtime_abi: u32,
    runtime_revision: String,
    generation: String,
    #[serde(rename = "minOS")]
    min_os: String,
}

fn prepare(json: &str) -> Result<(), String> {
    let request: Request = serde_json::from_str(json).map_err(|e| e.to_string())?;
    let args = nxb_build::Args {
        nsp_dir: request.input,
        keys: Some(request.keys),
        work_dir: Some(request.work),
        title_id: request.title_id,
        update_inputs: request.updates,
        aoc: request.dlc,
        base_package: request.base_package,
        threads: 2,
        auto_analyze: true,
        ..Default::default()
    };
    nxb_build::prepare_nxb(
        &args,
        &request.output,
        nxb_build::BuildMetadata {
            runtime_abi: request.runtime_abi,
            runtime_revision: request.runtime_revision,
            generation: request.generation,
            min_os: request.min_os,
        },
    )
}

/// Build a new unsigned NXB using the caller's real runtime metadata.
/// # Safety
/// `request_json` is a valid NUL-terminated UTF-8 string for the call duration.
/// If non-null, `error` points to at least `capacity` writable bytes, disjoint
/// from the request. No pointers are retained.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nxkit_prepare_nxb(
    request_json: *const c_char,
    error: *mut c_char,
    capacity: usize,
) -> i32 {
    let result = std::panic::catch_unwind(|| {
        if request_json.is_null() {
            return Err("Missing build request".to_owned());
        }
        // SAFETY: the caller supplies a NUL-terminated string for this call.
        let json = unsafe { CStr::from_ptr(request_json) }
            .to_str()
            .map_err(|e| e.to_string())?;
        prepare(json)
    })
    .unwrap_or_else(|_| Err("Game preparation failed unexpectedly".into()));
    let (status, message) = match result {
        Ok(()) => (0, String::new()),
        Err(e) => (1, e),
    };
    if !error.is_null() && capacity > 0 {
        let mut length = message.len().min(capacity - 1);
        while !message.is_char_boundary(length) {
            length -= 1;
        }
        // SAFETY: the caller supplies capacity writable bytes and disjoint buffers.
        unsafe {
            std::ptr::copy_nonoverlapping(message.as_ptr(), error.cast(), length);
            *error.add(length) = 0;
        }
    }
    status
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_missing_and_invalid_requests_without_unwinding() {
        let mut error = [0_i8; 24];
        assert_eq!(
            unsafe { nxkit_prepare_nxb(std::ptr::null(), error.as_mut_ptr(), error.len()) },
            1
        );
        assert_eq!(
            unsafe { CStr::from_ptr(error.as_ptr()) }.to_str().unwrap(),
            "Missing build request"
        );
        assert_eq!(
            unsafe { nxkit_prepare_nxb(c"{}".as_ptr(), error.as_mut_ptr(), error.len()) },
            1
        );
        assert_eq!(error[23], 0);
    }
}
