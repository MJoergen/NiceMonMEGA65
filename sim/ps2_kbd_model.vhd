-- A model of a PS/2 keyboard, for tb_ps2 and tb_ps2_nicemon: it sends the
-- frames that the testbench asks for, and takes the bytes that the host
-- sends it, the commands, which it answers with FA.
--
-- THEORY OF OPERATION
-- The lines are open drain: the model drives a line '0' or 'Z', and the
-- testbench pulls it up with 'H'. The model drives the clock, with a period
-- of 2 G_HALF, in both directions.
--
-- A toggle of send_i asks for a frame of byte_i: its first bits_i bits,
-- with the start ("01"), parity ("10"), or stop ("11") bit wrong as bad_i
-- says, and then a pause of 4 G_HALF. sent_o toggles back once it is sent.
-- The model changes the data while the clock is high. Before it pulls the
-- clock low for a bit, it checks that the host does not hold the clock low;
-- if the host does, the frame is broken off, the model takes the host's
-- byte, and then sends the whole frame again, as a keyboard does.
--
-- The host asks to send by holding the clock low and then the data, and
-- letting the clock go. The model then gives ten clock pulses and takes a
-- bit at each rising edge, the eight bits, the parity, and the stop bit,
-- and then the acknowledge: it holds the data low for an eleventh pulse.
-- A byte with the right parity and stop bit is counted in cmds_o and shown
-- in cmd_o, and while answer_i is '1' the model answers it with FA, after
-- delay_i, 1 ms unless the testbench says otherwise; a keyboard answers
-- within 20 ms, and the Nexys4DDR's PIC24 may answer later. A byte with a wrong bit is
-- counted in errs_o instead, and answered with FE, resend, while answer_i is
-- '1'.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity ps2_kbd_model is
   generic (
      G_HALF : time := 40 us
   );
   port (
      ps2_clk_io  : inout std_logic;
      ps2_data_io : inout std_logic;

      -- The frames to send
      send_i      : in  std_logic;
      byte_i      : in  std_logic_vector(7 downto 0);
      bits_i      : in  natural range 1 to 11;
      bad_i       : in  std_logic_vector(1 downto 0);
      sent_o      : out std_logic;

      -- The bytes from the host
      answer_i    : in  std_logic;
      delay_i     : in  time := 1 ms;
      cmd_o       : out std_logic_vector(7 downto 0);
      cmds_o      : out natural;
      errs_o      : out natural
   );
end entity ps2_kbd_model;

architecture simulation of ps2_kbd_model is

begin

   p_kbd : process
      variable sent_v   : std_logic := '0';
      variable cmds_v   : natural   := 0;
      variable errs_v   : natural   := 0;
      variable reply_v  : std_logic_vector(7 downto 0);
      variable answer_v : boolean;
      variable ok_v     : boolean;

      impure function host_holds return boolean is
      begin
         return to_x01(ps2_clk_io) = '0';
      end function host_holds;

      -- Takes the host's byte, once it holds the clock low. Sets answer_v
      -- and reply_v when the byte asks for an answer.
      procedure take is
         variable bits_v : std_logic_vector(9 downto 0);
      begin
         answer_v := false;
         if to_x01(ps2_clk_io) = '0' then
            wait until to_x01(ps2_clk_io) = '1';
         end if;
         if to_x01(ps2_data_io) /= '0' then
            -- The host held the clock, but asks for nothing
            return;
         end if;
         wait for G_HALF / 2;
         for i in 0 to 9 loop
            ps2_clk_io <= '0';
            wait for G_HALF;
            ps2_clk_io <= 'Z';
            bits_v(i)  := to_x01(ps2_data_io);
            wait for G_HALF;
         end loop;
         -- The acknowledge
         ps2_data_io <= '0';
         ps2_clk_io  <= '0';
         wait for G_HALF;
         ps2_clk_io  <= 'Z';
         wait for G_HALF / 2;
         ps2_data_io <= 'Z';
         wait for G_HALF / 2;
         if bits_v(9) = '1' and (xor bits_v(8 downto 0)) = '1' then
            cmds_v  := cmds_v + 1;
            cmd_o   <= bits_v(7 downto 0);
            cmds_o  <= cmds_v;
            reply_v := X"FA";
         else
            errs_v  := errs_v + 1;
            errs_o  <= errs_v;
            reply_v := X"FE";
         end if;
         answer_v := answer_i = '1';
      end procedure take;

      -- Sends the first n bits of a frame of byte b, then a pause; ok_v is
      -- false if the host broke it off.
      procedure frame(b   : std_logic_vector(7 downto 0);
                      n   : natural;
                      bad : std_logic_vector(1 downto 0)) is
         variable frame_v : std_logic_vector(10 downto 0);
      begin
         frame_v := '1' & not (xor b) & b & '0';
         case bad is
            when "01"   => frame_v(0)  := '1';
            when "10"   => frame_v(9)  := not frame_v(9);
            when "11"   => frame_v(10) := '0';
            when others => null;
         end case;
         ok_v := true;
         for i in 0 to n - 1 loop
            if host_holds then
               ps2_data_io <= 'Z';
               ok_v        := false;
               return;
            end if;
            if frame_v(i) = '0' then
               ps2_data_io <= '0';
            else
               ps2_data_io <= 'Z';
            end if;
            wait for G_HALF / 2;
            ps2_clk_io <= '0';
            wait for G_HALF;
            ps2_clk_io <= 'Z';
            wait for G_HALF / 2;
         end loop;
         ps2_data_io <= 'Z';
         wait for 4 * G_HALF;
      end procedure frame;

      -- Takes the host's byte, and answers it, until the host is done
      procedure serve is
      begin
         while host_holds loop
            take;
            if answer_v then
               wait for delay_i;
               loop
                  frame(reply_v, 11, "00");
                  exit when ok_v;
                  take;
               end loop;
            end if;
         end loop;
      end procedure serve;

   begin
      ps2_clk_io  <= 'Z';
      ps2_data_io <= 'Z';
      sent_o      <= '0';
      cmd_o       <= X"00";
      cmds_o      <= 0;
      errs_o      <= 0;

      loop
         if send_i = sent_v and not host_holds then
            wait until send_i /= sent_v or to_x01(ps2_clk_io) = '0';
         end if;
         if host_holds then
            serve;
         else
            loop
               frame(byte_i, bits_i, bad_i);
               exit when ok_v;
               serve;
            end loop;
            sent_v := send_i;
            sent_o <= sent_v;
         end if;
      end loop;
   end process p_kbd;

end architecture simulation;
