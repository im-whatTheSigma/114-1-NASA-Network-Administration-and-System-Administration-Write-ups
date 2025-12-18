-- Debian default Lua configuration file for PowerDNS Recursor

-- Load DNSSEC root keys from dns-root-data package.
-- Note: If you provide your own Lua configuration file, consider
-- running rootkeys.lua too.
dofile("/usr/share/pdns-recursor/lua-config/rootkeys.lua")

addTA('cscat.tw', "55391 13 2 c47876707d1ce64f6369d2ff09a320f2eb846e0af427541b3761c8570ebd8db0")