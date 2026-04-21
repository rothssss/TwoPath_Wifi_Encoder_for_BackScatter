// =============================================================================
// async_fifo : dual-clock asynchronous FIFO using Gray-coded pointers.
//
// Depth must be a power of two. Default 32 x 8 per spec (Block A).
//
// Pointers:
//   - Write pointer is (ADDR_W+1) bits: the top bit is the wrap flag for
//     full detection; lower ADDR_W bits index the memory.
//   - Same for read pointer.
//   - Gray-coded copies of the pointers are crossed through 2FF synchronizers
//     into the opposite clock domain to generate full/empty.
//
// full  = (wptr_gray == {~rptr_gray_sync[ADDR_W:ADDR_W-1], rptr_gray_sync[ADDR_W-2:0]})
// empty = (rptr_gray == wptr_gray_sync)
//
// Reset is active-low asynchronous; synchronously released in each domain by
// 2FF-synchronizing rst_n in the top-level (not done inside this block).
// =============================================================================
module async_fifo #(
    parameter DATA_W = 8,
    parameter DEPTH  = 32,
    parameter ADDR_W = 5   // = $clog2(DEPTH); must match DEPTH.
) (
    // Write side
    input  wire              wclk,
    input  wire              wrst_n,
    input  wire              wr_en,
    input  wire [DATA_W-1:0] wr_data,
    output wire              full,

    // Read side
    input  wire              rclk,
    input  wire              rrst_n,
    input  wire              rd_en,
    output wire [DATA_W-1:0] rd_data,
    output wire              empty
);

    // ---- Memory (inferred RAM) ------------------------------------------
    reg [DATA_W-1:0] mem [0:DEPTH-1];

    // ---- Write domain ----------------------------------------------------
    reg  [ADDR_W:0] wptr_bin;
    reg  [ADDR_W:0] wptr_gray;
    wire [ADDR_W:0] wptr_bin_next  = wptr_bin + {{ADDR_W{1'b0}}, (wr_en & ~full)};
    wire [ADDR_W:0] wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wptr_bin  <= {ADDR_W+1{1'b0}};
            wptr_gray <= {ADDR_W+1{1'b0}};
        end else begin
            wptr_bin  <= wptr_bin_next;
            wptr_gray <= wptr_gray_next;
        end
    end

    always @(posedge wclk) begin
        if (wr_en && !full) mem[wptr_bin[ADDR_W-1:0]] <= wr_data;
    end

    // ---- Read domain -----------------------------------------------------
    // Declare the read-domain pointer regs up front so the r2w synchronizer
    // below can reference `rptr_gray` without creating an implicit wire
    // (strict LRM; Xcelium rejects the later reg redeclaration).
    reg  [ADDR_W:0] rptr_bin;
    reg  [ADDR_W:0] rptr_gray;
    wire [ADDR_W:0] rptr_bin_next  = rptr_bin + {{ADDR_W{1'b0}}, (rd_en & ~empty)};
    wire [ADDR_W:0] rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;

    // Sync read-pointer (gray) into write domain
    wire [ADDR_W:0] rptr_gray_at_w;
    sync_2ff #(.WIDTH(ADDR_W+1), .RESET_VAL(1'b0)) u_sync_r2w (
        .clk(wclk), .rst_n(wrst_n),
        .d_in (rptr_gray),
        .d_out(rptr_gray_at_w)
    );

    // Full when wptr_gray equals read-pointer-gray with the upper two bits
    // inverted (classic Cummings async-FIFO formulation).
    assign full = (wptr_gray == {~rptr_gray_at_w[ADDR_W:ADDR_W-1],
                                  rptr_gray_at_w[ADDR_W-2:0]});

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rptr_bin  <= {ADDR_W+1{1'b0}};
            rptr_gray <= {ADDR_W+1{1'b0}};
        end else begin
            rptr_bin  <= rptr_bin_next;
            rptr_gray <= rptr_gray_next;
        end
    end

    // Sync write-pointer (gray) into read domain
    wire [ADDR_W:0] wptr_gray_at_r;
    sync_2ff #(.WIDTH(ADDR_W+1), .RESET_VAL(1'b0)) u_sync_w2r (
        .clk(rclk), .rst_n(rrst_n),
        .d_in (wptr_gray),
        .d_out(wptr_gray_at_r)
    );

    assign empty = (rptr_gray == wptr_gray_at_r);

    // Read data is combinational from memory at the current read address.
    // Downstream should register it if synchronous read is desired.
    assign rd_data = mem[rptr_bin[ADDR_W-1:0]];

endmodule
