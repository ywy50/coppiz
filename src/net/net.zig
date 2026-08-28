//! The replication wire (PRD 0003 phase 4; OQ 19 decided: own binary
//! framing over one TCP connection): the framing, the typed messages, and
//! the transport seam. The node loop and the CLI client build on this
//! module; a test swaps the TCP transport for the in-memory hub.

pub const framing = @import("framing.zig");
pub const message = @import("message.zig");
pub const transport = @import("transport.zig");
/// The CLI's wire client: short-lived commands against a serving node.
pub const client = @import("client.zig");
