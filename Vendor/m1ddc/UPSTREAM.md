Source: https://github.com/waydabber/m1ddc
Revision: 04d949794102eb8df01ad3681afff6464a3eede2
License: MIT (LICENSE). Only registry/transport files are vendored.
Changes: IORegistry iterator limit raised to 16; DDC wait increased to 50 ms;
Get-VCP checksum includes the 0x51 source address and does not accumulate on retries.
