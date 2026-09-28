//! Minimal Windows APIs: current-token elevation, owner ACLs, and user DPAPI.
use anyhow::{Context, Result};
use std::{ffi::c_void, os::windows::ffi::OsStrExt, path::Path, ptr};

#[repr(C)]
struct Blob {
    size: u32,
    data: *mut u8,
}

#[link(name = "crypt32")]
extern "system" {
    fn CryptProtectData(
        input: *const Blob,
        description: *const u16,
        entropy: *const Blob,
        reserved: *mut c_void,
        prompt: *mut c_void,
        flags: u32,
        output: *mut Blob,
    ) -> i32;
    fn CryptUnprotectData(
        input: *const Blob,
        description: *mut *mut u16,
        entropy: *const Blob,
        reserved: *mut c_void,
        prompt: *mut c_void,
        flags: u32,
        output: *mut Blob,
    ) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn LocalFree(memory: *mut c_void) -> *mut c_void;
    fn GetCurrentProcess() -> *mut c_void;
    fn CloseHandle(handle: *mut c_void) -> i32;
}

#[link(name = "advapi32")]
extern "system" {
    fn OpenProcessToken(process: *mut c_void, access: u32, token: *mut *mut c_void) -> i32;
    fn GetTokenInformation(
        token: *mut c_void,
        class: u32,
        info: *mut c_void,
        size: u32,
        length: *mut u32,
    ) -> i32;
    fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text: *const u16,
        revision: u32,
        descriptor: *mut *mut c_void,
        size: *mut u32,
    ) -> i32;
    fn SetFileSecurityW(path: *const u16, information: u32, descriptor: *mut c_void) -> i32;
}

pub fn owner_only(path: &Path, directory: bool) -> Result<()> {
    // Protected DACL granting only the object's owner. Directory children inherit it.
    let sddl = if directory {
        "D:P(A;OICI;FA;;;OW)"
    } else {
        "D:P(A;;FA;;;OW)"
    };
    let sddl: Vec<u16> = sddl.encode_utf16().chain(Some(0)).collect();
    let path: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    let mut descriptor = ptr::null_mut();
    unsafe {
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        ) == 0
        {
            return Err(std::io::Error::last_os_error()).context("Create owner-only ACL");
        }
        let ok = SetFileSecurityW(path.as_ptr(), 0x80000004, descriptor);
        let error = std::io::Error::last_os_error();
        LocalFree(descriptor);
        if ok == 0 {
            return Err(error).context("Apply owner-only ACL");
        }
    }
    Ok(())
}

pub fn administrator() -> bool {
    let mut token = ptr::null_mut();
    unsafe {
        if OpenProcessToken(GetCurrentProcess(), 0x0008, &mut token) == 0 {
            return false;
        }
        let mut elevated: u32 = 0;
        let mut length = 0;
        let ok = GetTokenInformation(
            token,
            20,
            &mut elevated as *mut u32 as *mut c_void,
            4,
            &mut length,
        );
        CloseHandle(token);
        ok != 0 && elevated != 0
    }
}

fn crypt(bytes: &[u8], decrypt: bool) -> Result<Vec<u8>> {
    anyhow::ensure!(bytes.len() <= u32::MAX as usize, "Secret is too large");
    let input = Blob {
        size: bytes.len() as u32,
        data: bytes.as_ptr() as *mut u8,
    };
    let mut output = Blob {
        size: 0,
        data: ptr::null_mut(),
    };
    unsafe {
        let ok = if decrypt {
            CryptUnprotectData(
                &input,
                ptr::null_mut(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                1,
                &mut output,
            )
        } else {
            CryptProtectData(
                &input,
                ptr::null(),
                ptr::null(),
                ptr::null_mut(),
                ptr::null_mut(),
                1,
                &mut output,
            )
        };
        if ok == 0 {
            return Err(std::io::Error::last_os_error()).context("Windows user DPAPI");
        }
        let value = std::slice::from_raw_parts(output.data, output.size as usize).to_vec();
        LocalFree(output.data.cast());
        Ok(value)
    }
}

pub fn protect(bytes: &[u8]) -> Result<Vec<u8>> {
    crypt(bytes, false)
}
pub fn unprotect(bytes: &[u8]) -> Result<Vec<u8>> {
    crypt(bytes, true)
}
