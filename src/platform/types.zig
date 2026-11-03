//! Portable values exchanged with OS backends. No OS handles or ABI layouts.
pub const Interest = struct { readable: bool = false, writable: bool = false };
pub const Event = struct { tag: u64, readable: bool, writable: bool, closed: bool };
pub const Region = struct { x: i32, y: i32, w: u32, h: u32 };
pub const CaptureBand = struct { region: Region, off: usize, stride: usize };
pub const TcpInfo = struct {
    rto_us: u32 = 0,
    rtt_us: u32 = 0,
    total_retrans: u32 = 0,
    ooo: u32 = 0,
    segs_in: u32 = 0,
};
