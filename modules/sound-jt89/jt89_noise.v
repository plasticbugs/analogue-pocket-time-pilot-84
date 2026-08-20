/*  This file is part of JT89.

    JT89 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT89 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT89.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: March, 8th 2017

    This work was originally based in the implementation found on the
    SMS core of MiST

    */

module jt89_noise(
    input               clk,
(* direct_enable = 1 *) input   clk_en,
    input               rst,
    input               clr,
    input         [2:0] ctrl3,
    input         [3:0] vol,
    input               tone2,
    output        [8:0] snd
);

reg [16:0] shift;
reg [10:0] cnt;
reg        update, tone_en, tone2_l;
wire       up;

assign up = tone_en ? tone2 & ~tone2_l : cnt==1;

jt89_vol u_vol(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .din    ( shift[0]  ),
    .vol    ( vol       ),
    .snd    ( snd       )
);

always @(posedge clk)
    if( rst ) begin
        cnt     <= 0;
        tone_en <= 0;
    end else if( clk_en ) begin
        tone_en <= ctrl3[1:0]==3;
        tone2_l <= tone2;

        if( cnt==11'd1 ) begin
            case( ctrl3[1:0] )
                2'd0: cnt <= 11'h20; // clk_en already divides by 16
                2'd1: cnt <= 11'h40;
                2'd2: cnt <= 11'h80;
                default:;
            endcase
        end else begin
            cnt <= cnt-11'b1;
        end
    end

// LOCAL FIX (not upstream): jt89 is derived from the SMS core of MiST, and
// the SMS PSG is not the chip on this board. Time Pilot '84 has discrete
// SN76489A parts, whose noise generator MAME models as a 17-bit register with
// white-noise taps at bits 2 and 3, feedback inserted at bit 16, and periodic
// noise fed back from bit 2 alone:
//
//   sn76489a_device(..., 0x10000, 0x04, 0x08, false, ...)
//   fb = (RNG & 0x04) != (((RNG & 0x08) != 0) && white)
//   RNG >>= 1;  if (fb) RNG |= 0x10000;  out = RNG & 1;
//
// jt89 had a 16-bit register with taps 0 and 3 -- the SMS arrangement -- which
// gives a different noise sequence and a different periodic-noise pitch. This
// is what bullets and explosions are made of, so it is audible.
wire fb = shift[2] ^ (ctrl3[2] & shift[3]);

always @(posedge clk)
    if( rst || clr )
        shift <= 17'h1_0000;          // MAME resets the RNG to the feedback mask
    else if( clk_en ) begin
        if( up ) begin
            // all-zero is a fixed point for this feedback, so guard it
            shift <= (shift == 17'd0) ? 17'h1_0000 : {fb, shift[16:1]};
        end
    end

endmodule
