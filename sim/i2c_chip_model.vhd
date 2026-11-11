-- A model of a chip on an I2C bus with registers, for tb_i2c and tb_cosim
-- (#105): the real-time clocks of the MEGA65, the RV-3032-C7 of the R6 and
-- the ISL12020M of the R3, and the Nexys4DDR's temperature sensor, the
-- ADT7420, are all such chips.
--
-- THEORY OF OPERATION
-- The chip answers its address, G_ADDR. It has 32 registers, register i
-- in bits 8 i + 7 .. 8 i of G_REGS, and a pointer to them. A write's first
-- byte sets the pointer, and each byte after it is written to the
-- register at the pointer; a read sends the register at the pointer, and
-- each byte, written or read, moves the pointer on, from 31 to 0. So a
-- write of the register alone, and then a read with a repeated START or
-- after STOP, reads from that register, as the chips do.
--
-- The lines are open drain: the model drives a line '0' or 'Z', and the
-- testbench pulls it up with 'H'. It takes SDA on the rising edge of SCL,
-- and changes it after the falling edge. START is SDA falling while SCL is
-- high, and STOP is SDA rising while SCL is high. After each ACK that it
-- sends, it holds SCL low for G_STRETCH, which stretches the clock. It
-- checks that SDA changes while SCL is high only as START or STOP.
--
-- With G_STUCK > 0, the chip starts as if a reset of the master had left
-- it in the middle of a read: it holds SDA low for the next G_STUCK pulses
-- of SCL, and then lets it go.

library ieee;
   use ieee.std_logic_1164.all;
   use ieee.numeric_std_unsigned.all;

entity i2c_chip_model is
   generic (
      G_ADDR    : std_logic_vector(6 downto 0);
      G_REGS    : std_logic_vector(255 downto 0) := (others => '0');
      G_STRETCH : time                           := 0 ns;
      G_STUCK   : natural                        := 0
   );
   port (
      scl_io : inout std_logic := 'Z';
      sda_io : inout std_logic := 'Z'
   );
end entity i2c_chip_model;

architecture simulation of i2c_chip_model is

   type t_state is (
      IDLE_ST, STUCK_ST, ADDR_ST, ACK_ADDR_ST, WRITE_ST, ACK_WRITE_ST, READ_ST,
      ACK_READ_ST, NEXT_ST
   );

begin

   p_chip : process
      variable regs_v  : std_logic_vector(255 downto 0) := G_REGS;
      variable state_v : t_state                        := IDLE_ST;
      variable scl_v   : std_logic                      := '1';
      variable sda_v   : std_logic                      := '1';
      variable old_scl : std_logic                      := '1';
      variable old_sda : std_logic                      := '1';
      variable shreg_v : std_logic_vector(7 downto 0)   := (others => '0');
      variable bits_v  : natural                        := 0;
      variable ptr_v   : natural range 0 to 31          := 0;
      variable read_v  : boolean                        := false;
      variable first_v : boolean                        := false;
      variable stuck_v : natural                        := G_STUCK;

      impure function reg return std_logic_vector is
      begin
         return regs_v(8 * ptr_v + 7 downto 8 * ptr_v);
      end function reg;

      procedure drive (b : std_logic) is
      begin
         if b = '0' then
            sda_io <= '0';
         else
            sda_io <= 'Z';
         end if;
      end procedure drive;

   begin
      if G_STUCK > 0 then
         state_v := STUCK_ST;
         sda_io  <= '0';
      end if;

      loop
         wait on scl_io, sda_io;
         scl_v := to_x01(scl_io);
         sda_v := to_x01(sda_io);

         if scl_v = '1' and old_scl = '1' and sda_v /= old_sda then
            -- START or STOP. The chip's own SDA changes only while SCL is
            -- low, so it is the master's.
            if state_v /= STUCK_ST then
               sda_io <= 'Z';
               if sda_v = '0' then
                  state_v := ADDR_ST;
                  bits_v  := 0;
               else
                  state_v := IDLE_ST;
               end if;
            end if;
         elsif scl_v = '1' and old_scl = '0' then
            -- The rising edge: a bit taken, or the master's ACK
            case state_v is

               when ADDR_ST | WRITE_ST =>
                  shreg_v := shreg_v(6 downto 0) & sda_v;
                  bits_v  := bits_v + 1;

               when ACK_READ_ST =>
                  if sda_v = '0' then
                     ptr_v   := (ptr_v + 1) mod 32;
                     state_v := NEXT_ST;
                  else
                     ptr_v   := (ptr_v + 1) mod 32;
                     state_v := IDLE_ST;
                  end if;

               when others =>
                  null;

            end case;

         elsif scl_v = '0' and old_scl = '1' then
            -- The falling edge: SDA changes for the next bit
            case state_v is

               when STUCK_ST =>
                  if stuck_v <= 1 then
                     sda_io  <= 'Z';
                     state_v := IDLE_ST;
                  else
                     stuck_v := stuck_v - 1;
                  end if;

               when ADDR_ST =>
                  if bits_v = 8 then
                     if shreg_v(7 downto 1) = G_ADDR then
                        sda_io  <= '0';
                        read_v  := shreg_v(0) = '1';
                        state_v := ACK_ADDR_ST;
                     else
                        state_v := IDLE_ST;
                     end if;
                  end if;

               when ACK_ADDR_ST | ACK_WRITE_ST =>
                  if G_STRETCH > 0 ns then
                     scl_io <= '0';
                     wait for G_STRETCH;
                     scl_io <= 'Z';
                  end if;
                  if read_v then
                     shreg_v := reg;
                     drive(shreg_v(7));
                     bits_v  := 1;
                     state_v := READ_ST;
                  else
                     sda_io  <= 'Z';
                     first_v := state_v = ACK_ADDR_ST;
                     bits_v  := 0;
                     state_v := WRITE_ST;
                  end if;

               when WRITE_ST =>
                  if bits_v = 8 then
                     if first_v then
                        ptr_v := to_integer(shreg_v(4 downto 0));
                     else
                        regs_v(8 * ptr_v + 7 downto 8 * ptr_v) := shreg_v;
                        ptr_v                                  := (ptr_v + 1) mod 32;
                     end if;
                     sda_io  <= '0';
                     state_v := ACK_WRITE_ST;
                  end if;

               when READ_ST =>
                  if bits_v = 8 then
                     sda_io  <= 'Z';
                     state_v := ACK_READ_ST;
                  else
                     drive(shreg_v(7 - bits_v));
                     bits_v := bits_v + 1;
                  end if;

               when NEXT_ST =>
                  shreg_v := reg;
                  drive(shreg_v(7));
                  bits_v  := 1;
                  state_v := READ_ST;

               when others =>
                  null;

            end case;

         end if;

         old_scl := scl_v;
         old_sda := to_x01(sda_io);
      end loop;
   end process p_chip;

end architecture simulation;
