//! Two agents through the C ABI: exchange credentials
//! and candidates, pump checks/responses, both nominate.

use dc_ice_ffi::*;
use std::ffi::CString;

fn get_str(h: *const GrpcdcIce, f: unsafe extern "C" fn(*const GrpcdcIce, *mut std::ffi::c_char, usize) -> i64) -> String {
    let mut buf = vec![0u8; 128];
    let n = unsafe { f(h, buf.as_mut_ptr() as *mut std::ffi::c_char, buf.len()) };
    assert!(n >= 0);
    String::from_utf8_lossy(&buf[..n as usize]).into_owned()
}

/// Unframe (packet, addr) pairs.
fn unframe(data: &[u8]) -> Vec<(Vec<u8>, String)> {
    let mut out = Vec::new();
    let mut p = 0;
    while p < data.len() {
        let plen = u32::from_be_bytes(data[p..p + 4].try_into().unwrap()) as usize;
        p += 4;
        let packet = data[p..p + plen].to_vec();
        p += plen;
        let alen = u16::from_be_bytes(data[p..p + 2].try_into().unwrap()) as usize;
        p += 2;
        let addr = String::from_utf8_lossy(&data[p..p + alen]).into_owned();
        p += alen;
        out.push((packet, addr));
    }
    out
}

fn unframe_events(data: &[u8]) -> Vec<(u8, String)> {
    let mut out = Vec::new();
    let mut p = 0;
    while p < data.len() {
        let kind = data[p];
        p += 1;
        let alen = u16::from_be_bytes(data[p..p + 2].try_into().unwrap()) as usize;
        p += 2;
        out.push((kind, String::from_utf8_lossy(&data[p..p + alen]).into_owned()));
        p += alen;
    }
    out
}

/// One pump direction: `from`'s due checks go to `to`
/// (source = from_addr); responses return to `from`
/// (source = to_addr). Nominated events are attributed to
/// the agent that emitted them.
#[allow(clippy::too_many_arguments)]
unsafe fn pump(
    from: *mut GrpcdcIce,
    to: *mut GrpcdcIce,
    from_addr: &str,
    to_addr: &str,
    out: &mut [u8],
    events: &mut [u8],
    nominated_from: &mut bool,
    nominated_to: &mut bool,
) {
    let mut events_len = 0usize;
    let n = grpcdc_ice_due_checks(from, out.as_mut_ptr(), out.len());
    assert!(n >= 0);
    for (packet, _addr) in unframe(&out[..n as usize].to_vec()) {
        events_len = 0;
        let m = grpcdc_ice_handle_stun(
            to, packet.as_ptr(), packet.len(),
            CString::new(from_addr).unwrap().as_ptr(),
            out.as_mut_ptr(), out.len(),
            events.as_mut_ptr(), events.len(), &mut events_len,
        );
        assert!(m >= 0, "handle_stun {m}");
        for (kind, _) in unframe_events(&events[..events_len].to_vec()) {
            if kind == 2 {
                *nominated_to = true;
            }
        }
        for (resp, _) in unframe(&out[..m as usize].to_vec()) {
            events_len = 0;
            let k = grpcdc_ice_handle_stun(
                from, resp.as_ptr(), resp.len(),
                CString::new(to_addr).unwrap().as_ptr(),
                out.as_mut_ptr(), out.len(),
                events.as_mut_ptr(), events.len(), &mut events_len,
            );
            assert!(k >= 0);
            for (kind, _) in unframe_events(&events[..events_len].to_vec()) {
                if kind == 2 {
                    *nominated_from = true;
                }
            }
        }
    }
}

#[test]
fn two_agents_nominate_through_the_abi() {
    unsafe {
        let a = grpcdc_ice_new(1);
        let b = grpcdc_ice_new(0);
        assert_eq!(grpcdc_ice_add_local_host(a, CString::new("127.0.0.1:4000").unwrap().as_ptr()), 0);
        assert_eq!(grpcdc_ice_add_local_host(b, CString::new("127.0.0.1:5000").unwrap().as_ptr()), 0);

        let (auf, apw) = (get_str(a, grpcdc_ice_local_ufrag), get_str(a, grpcdc_ice_local_pwd));
        let (buf_, bpw) = (get_str(b, grpcdc_ice_local_ufrag), get_str(b, grpcdc_ice_local_pwd));
        assert!(!auf.is_empty() && !buf_.is_empty());
        grpcdc_ice_set_remote(a, CString::new(buf_).unwrap().as_ptr(), CString::new(bpw).unwrap().as_ptr());
        grpcdc_ice_set_remote(b, CString::new(auf).unwrap().as_ptr(), CString::new(apw).unwrap().as_ptr());

        // Candidate lines the way a host would signal them.
        let a_cand = "candidate:h0 1 udp 2130706431 127.0.0.1 4000 typ host";
        let b_cand = "candidate:h0 1 udp 2130706431 127.0.0.1 5000 typ host";
        assert_eq!(grpcdc_ice_add_remote_candidate(a, CString::new(b_cand).unwrap().as_ptr()), 1);
        assert_eq!(grpcdc_ice_add_remote_candidate(b, CString::new(a_cand).unwrap().as_ptr()), 1);

        let mut out = vec![0u8; 65536];
        let mut events = vec![0u8; 4096];
        let mut nominated_a = false;
        let mut nominated_b = false;
        for _round in 0..60 {
            pump(a, b, "127.0.0.1:4000", "127.0.0.1:5000",
                 &mut out, &mut events, &mut nominated_a, &mut nominated_b);
            pump(b, a, "127.0.0.1:5000", "127.0.0.1:4000",
                 &mut out, &mut events, &mut nominated_b, &mut nominated_a);
            std::thread::sleep(std::time::Duration::from_millis(50));
            if nominated_a && nominated_b {
                break;
            }
        }
        assert!(nominated_a && nominated_b, "both nominated via ABI events");
        let nom_a = get_str(a, grpcdc_ice_nominated);
        let nom_b = get_str(b, grpcdc_ice_nominated);
        assert_eq!(nom_a, "127.0.0.1:5000");
        assert_eq!(nom_b, "127.0.0.1:4000");
        grpcdc_ice_free(a);
        grpcdc_ice_free(b);
    }
}
