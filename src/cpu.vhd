-- cpu.vhd: Simple 8-bit CPU (BrainFuck interpreter)
-- Copyright (C) 2022 Brno University of Technology,
--                    Faculty of Information Technology
-- Author(s): jmeno <login AT stud.fit.vutbr.cz>
--
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

-- ----------------------------------------------------------------------------
--                        Entity declaration
-- ----------------------------------------------------------------------------
entity cpu is
 port (
   CLK   : in std_logic;  -- hodinovy signal
   RESET : in std_logic;  -- asynchronni reset procesoru
   EN    : in std_logic;  -- povoleni cinnosti procesoru
 
   -- synchronni pamet RAM
   DATA_ADDR  : out std_logic_vector(12 downto 0); -- adresa do pameti
   DATA_WDATA : out std_logic_vector(7 downto 0); -- mem[DATA_ADDR] <- DATA_WDATA pokud DATA_EN='1'
   DATA_RDATA : in std_logic_vector(7 downto 0);  -- DATA_RDATA <- ram[DATA_ADDR] pokud DATA_EN='1'
   DATA_RDWR  : out std_logic;                    -- cteni (0) / zapis (1)
   DATA_EN    : out std_logic;                    -- povoleni cinnosti
   
   -- vstupni port
   IN_DATA   : in std_logic_vector(7 downto 0);   -- IN_DATA <- stav klavesnice pokud IN_VLD='1' a IN_REQ='1'
   IN_VLD    : in std_logic;                      -- data platna
   IN_REQ    : out std_logic;                     -- pozadavek na vstup data
   
   -- vystupni port
   OUT_DATA : out  std_logic_vector(7 downto 0);  -- zapisovana data
   OUT_BUSY : in std_logic;                       -- LCD je zaneprazdnen (1), nelze zapisovat
   OUT_WE   : out std_logic                       -- LCD <- OUT_DATA pokud OUT_WE='1' a OUT_BUSY='0'
 );
end cpu;


-- ----------------------------------------------------------------------------
--                      Architecture declaration
-- ----------------------------------------------------------------------------
architecture behavioral of cpu is
  signal cnt_out : std_logic_vector (13 downto 0);
  signal cnt_inc : std_logic;
  signal cnt_dec : std_logic;

  signal pc_addr : std_logic_vector (11 downto 0); -- memory adress of code 
  signal pc_inc : std_logic;
  signal pc_dec : std_logic;
  signal pc_clear : std_logic;

  signal ptr_addr : std_logic_vector (11 downto 0); -- memory adress of data
  signal ptr_inc : std_logic;
  signal ptr_dec : std_logic;
  signal ptr_clear : std_logic;
 
  signal mx1_sel : std_logic; -- select for multiplexor 1 (adress)
  
  signal mx2_sel : std_logic_vector (1 downto 0); -- two bit selector for multiplexor 2 (write)

  type fsm_state is (START, FETCH, DECODE, NEXT_CELL, PREV_CELL, INC_DATA1, INC_DATA2, INC_DATA3,
                     DEC_DATA1, DEC_DATA2, DEC_DATA3, PRINT1, PRINT2, INPUT1, INPUT2, WHILE1,
                     WHILE2, WHILE_SKIP1, WHILE_SKIP2, WHILE_END1, WHILE_END2, WHILE_BTRACK1, 
                     WHILE_BTRACK2, WHILE_BTRACK3, S_OTHERS, EOF);
  
  signal curr_state : fsm_state := START;
  signal next_state : fsm_state;

begin

cnt: process(CLK, RESET, cnt_inc, cnt_dec)
begin
  if (RESET = '1') then
    cnt_out <= (others => '0');
  elsif (CLK'event) and (CLK = '1') then
    if (cnt_inc = '1') then
      cnt_out <= (cnt_out + 1);
    elsif (cnt_dec = '1') then
      cnt_out <= (cnt_out - 1);
    end if; 
  end if;
end process cnt;

pc: process(CLK, RESET, pc_inc, pc_dec) -- code pointer
begin
  if (RESET = '1') then
    pc_addr <= (others => '0');
  elsif (CLK'event) and (CLK = '1') then
    if (pc_inc = '1') then
      pc_addr <= (pc_addr + 1);
    elsif (pc_dec = '1') then
      pc_addr <= (pc_addr - 1);
    elsif (pc_clear = '1') then
      pc_addr <= (others => '0');
    end if; 
  end if;
end process pc;

ptr: process(CLK, RESET, ptr_inc, ptr_dec) -- data pointer
begin
  if (RESET = '1') then
    ptr_addr <= (others => '0');
  elsif (CLK'event) and (CLK = '1') then
    if (ptr_inc = '1') then
      ptr_addr <= (ptr_addr + 1);
    elsif (ptr_dec = '1') then
      ptr_addr <= (ptr_addr - 1);
    elsif (ptr_clear = '1') then
      ptr_addr <= (others => '0');
    end if; 
  end if;
end process ptr;

mx1: process(mx1_sel) -- multiplexor for choosing data adress source
begin 
  if (mx1_sel = '0') then
    DATA_ADDR <= '0' & pc_addr; -- choosing to use code ptr
  elsif (mx1_sel = '1') then
    DATA_ADDR <= '1' & ptr_addr; -- choosing to use data ptr
  end if;
end process mx1;

mx2: process(mx2_sel) -- multiplexor for choosing data input (read, inc or dec)
begin 
  if (mx2_sel = "11") then
    DATA_WDATA <= IN_DATA; -- choosing to write from user input
  elsif (mx2_sel = "10") then
    DATA_WDATA <= (DATA_RDATA - 1); -- choosing to decrement current cell
  elsif (mx2_sel = "01") then
    DATA_WDATA <= (DATA_RDATA + 1); -- choosing to increment current cell
  end if;
end process mx2;

fsm_next: process(CLK, RESET)
begin
  if (RESET = '1') then
    curr_state <= START;
  elsif (CLK'event) and (CLK = '1') then
    if (EN = '1') then
      curr_state <= next_state;      
    end if ;
  end if ;
end process fsm_next;

fsm_current: process(curr_state, DATA_RDATA, OUT_BUSY, IN_VLD)
begin
  IN_REQ    <= '0';
  OUT_WE    <= '0';
  DATA_EN   <= '0';
  DATA_RDWR <= '0'; -- default: read mode

  cnt_inc   <= '0';
  cnt_dec   <= '0';
  
  pc_inc    <= '0';
  pc_dec    <= '0';
  pc_clear  <= '0';
  
  ptr_inc   <= '0';
  ptr_dec   <= '0';
  ptr_clear <= '0';

  mx1_sel <= '0';
  mx2_sel <= "00";

  case curr_state is
  
    when START =>
      pc_clear <= '1';
      ptr_clear <= '1';
      mx1_sel <= '1';

      next_state <= FETCH;

    when FETCH =>
      mx1_sel <= '0';
      DATA_EN <= '1';
      DATA_RDWR <= '0';
      
      next_state <= DECODE;

    when DECODE => -- decoding char to choose function to run
      case DATA_RDATA is

        when "00111110" => -- '>' = increment data pointer
          next_state <= NEXT_CELL;
      
        when "00111100" => -- '<' = decrement data pointer
          next_state <= PREV_CELL;

        when "00101011" => -- '+' = increment value
          next_state <= INC_DATA1;
        
        when "00101101" => -- '-' = decrement value
          next_state <= DEC_DATA1;

        when "00101110" => -- '.' = print
          next_state <= PRINT1;

        when "00101100" => -- ',' = input
          next_state <= INPUT1;
        
        when "01011011" => -- '[' = while
          next_state <= WHILE1;

        when "01011101" => -- ']' = while_end
          next_state <= WHILE_END1;

        when "00101001" => -- ')' = while_end
          next_state <= WHILE_END1;

        when "00000000" => -- 'null' = EOF
          next_state <= EOF;

        when others => -- anything else
          next_state <= S_OTHERS;

      end case ;
    
    when NEXT_CELL =>
      mx1_sel <= '1'; -- updating adress
      ptr_inc <= '1'; -- incrementing code pointer
      pc_inc <= '1'; 
      next_state <= FETCH;

    when PREV_CELL =>
      mx1_sel <= '1'; -- updating adress
      ptr_dec <= '1'; -- decrementing code pointer
      pc_inc <= '1'; 
      next_state <= FETCH;
    
    when INC_DATA1 =>
      mx1_sel <= '1'; -- choosing data adress to read from (takes 2 * CLK = 1)
      DATA_EN <= '1';
      next_state <= INC_DATA2;

    when INC_DATA2 => -- waiting for data to be on input
      next_state <= INC_DATA3;

    when INC_DATA3 => -- data on input
      mx1_sel <= '1'; -- updating mx1
      mx2_sel <= "01"; -- incrementing data
      DATA_RDWR <= '1'; -- write mode
      DATA_EN <= '1';
      pc_inc <= '1';
      next_state <= FETCH;

    when DEC_DATA1 =>
      mx1_sel <= '1'; -- choosing data adress to read from
      DATA_EN <= '1';
      next_state <= DEC_DATA2;

    when DEC_DATA2 => -- waiting for data to be on input
      next_state <= DEC_DATA3;

    when DEC_DATA3 =>
      mx1_sel <= '1'; -- choosing data adress to write to
      mx2_sel <= "10"; -- decrementing data
      DATA_RDWR <= '1'; -- write mode
      DATA_EN <= '1';
      pc_inc <= '1';
      next_state <= FETCH;

    when PRINT1 => -- read
      mx1_sel <= '1'; -- choosing data adress to read from
      DATA_EN <= '1';
      next_state <= PRINT2;

    when PRINT2 => -- got data, if not busy, printing
      if (OUT_BUSY = '1') then
        next_state <= PRINT1;
      else
        OUT_DATA <= DATA_RDATA;
        OUT_WE <= '1';
        mx1_sel <= '1'; -- updating DATA_ADDR
        pc_inc <= '1';
        next_state <= FETCH;
      end if ;

    when INPUT1 => -- requesting input and waiting
      IN_REQ <= '1';
      if (IN_VLD = '0') then
        next_state <= INPUT1;
      else
        next_state <= INPUT2;
      end if;
    
    when INPUT2 => -- read
      mx1_sel <= '1'; -- choosing data adress to write to
      mx2_sel <= "11"; -- choosing user input
      DATA_RDWR <= '1'; -- write mode
      DATA_EN <= '1';
      pc_inc <= '1';
      next_state <= FETCH;

    when WHILE1 =>
      DATA_EN <= '1';
      mx1_sel <= '1'; -- reading from memory
      pc_inc <= '1';
      next_state <= WHILE2;
        
    when WHILE2 =>
      if (DATA_RDATA = "00000000") then -- not a cycle, skipping
        cnt_inc <= '1'; -- cnt set to 1
        next_state <= WHILE_SKIP1;
      else
        next_state <= FETCH;
      end if;

    when WHILE_SKIP1 =>
      DATA_EN <= '1';
      mx1_sel <= '0'; -- reading code
      next_state <= WHILE_SKIP2;

    when WHILE_SKIP2 => 
      if (cnt_out /= "00000000") then
        mx1_sel <= '1'; -- updating DATA_ADDR
        if (DATA_RDATA = "01011011") then -- tmp = '['
          cnt_inc <= '1';
        elsif (DATA_RDATA = "01011101") then -- tmp = ']'
          cnt_dec <= '1';
        end if;
        pc_inc <= '1';
        next_state <= WHILE_SKIP1;
      else
        next_state <= FETCH;
      end if;

    when WHILE_END1 =>
      DATA_EN <= '1';
      mx1_sel <= '1'; -- reading from memory
      next_state <= WHILE_END2;
  
    when WHILE_END2 =>
      if (DATA_RDATA = "00000000") then -- value of current cell is 0, skipping
        pc_inc <= '1';
        mx1_sel <= '1'; -- updating DATA_ADDR
        next_state <= FETCH;
      else 
        cnt_inc <= '1';
        pc_dec <= '1';
        mx1_sel <= '1'; -- updating DATA_ADDR
        next_state <= WHILE_BTRACK1;
      end if;

    when WHILE_BTRACK1 => -- waiting for DATA_RDATA change
      DATA_EN <= '1';
      mx1_sel <= '0'; -- reading from code
      next_state <= WHILE_BTRACK2;
  
    when WHILE_BTRACK2 =>
      if (cnt_out /= "00000000") then
        if (DATA_RDATA = "01011101" or DATA_RDATA = "00101001") then -- ']' or ')'
          cnt_inc <= '1';
        elsif (DATA_RDATA = "01011011" or DATA_RDATA = "00101000") then -- '[' or '('
          cnt_dec <= '1';
        end if;
        next_state <= WHILE_BTRACK3;
      else
        next_state <= FETCH;
      end if;
    
    when WHILE_BTRACK3 =>
      if (cnt_out = "00000000") then -- ending the backtrack
        pc_inc <= '1';
        mx1_sel <= '1'; -- updating DATA_ADDR
      else
        pc_dec <= '1';
        mx1_sel <= '1'; -- updating DATA_ADDR
      end if;
      next_state <= WHILE_BTRACK1;

    when S_OTHERS => 
      pc_inc <= '1';
      mx1_sel <= '1'; -- updating DATA_ADDR
      next_state <= FETCH;
      
    when EOF =>
      next_state <= EOF;
      
  end case;
end process fsm_current;

end behavioral;