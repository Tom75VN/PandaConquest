PandaConquest = PandaConquest or {}

local PC = PandaConquest
local Ed25519 = {}
PC.Ed25519 = Ed25519

-- Ed25519 signature verification for the membership tickets (decision 0061),
-- in Lua 5.0 with doubles only. A port of TweetNaCl's crypto_sign_open
-- (public domain): field elements are 16 limbs of 16 bits (index 0 to 15),
-- every product stays below 2^53. Verification only: no secret is ever handled,
-- so nothing needs to run in constant time. The double scalar multiplication
-- uses 4-bit windows (Straus) instead of TweetNaCl's ladder, about three times
-- fewer point additions. bit.bxor is the only bit operation used, given signed
-- operands and read back unsigned, as in modules/import.lua (its sign
-- convention on OctoWoW is not measured); every other bit operation is
-- arithmetic. Pass a pause function to Verify to spread the work over frames.

local floor = math.floor
local U32 = 4294967296
local I31 = 2147483648

local function Mod(x, m)
  return x - floor(x / m) * m
end

local function Gf(init)
  local r = {}
  local i
  for i = 0, 15 do r[i] = (init and init[i + 1]) or 0 end
  return r
end

local GF0 = Gf()
local GF1 = Gf({ 1 })
local D = Gf({ 30883, 4953, 19914, 30187, 55467, 16705, 2637, 112, 59544, 30585, 16505, 36039, 65139, 11119, 27886, 20995 })
local D2 = Gf({ 61785, 9906, 39828, 60374, 45398, 33411, 5274, 224, 53552, 61171, 33010, 6542, 64743, 22239, 55772, 9222 })
local BX = Gf({ 54554, 36645, 11616, 51542, 42930, 38181, 51040, 26924, 56412, 64982, 57905, 49316, 21502, 52590, 14035, 8553 })
local BY = Gf({ 26200, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214, 26214 })
local SQRTM1 = Gf({ 41136, 18958, 6951, 50414, 58488, 44335, 6150, 12099, 55207, 15867, 153, 11085, 57099, 20417, 9344, 11139 })
local L = { 237, 211, 245, 92, 26, 99, 18, 88, 214, 156, 247, 162, 222, 249, 222, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16 }
local K = { 1116352408, 3609767458, 1899447441, 602891725, 3049323471, 3964484399, 3921009573, 2173295548, 961987163, 4081628472, 1508970993, 3053834265, 2453635748, 2937671579, 2870763221, 3664609560, 3624381080, 2734883394, 310598401, 1164996542, 607225278, 1323610764, 1426881987, 3590304994, 1925078388, 4068182383, 2162078206, 991336113, 2614888103, 633803317, 3248222580, 3479774868, 3835390401, 2666613458, 4022224774, 944711139, 264347078, 2341262773, 604807628, 2007800933, 770255983, 1495990901, 1249150122, 1856431235, 1555081692, 3175218132, 1996064986, 2198950837, 2554220882, 3999719339, 2821834349, 766784016, 2952996808, 2566594879, 3210313671, 3203337956, 3336571891, 1034457026, 3584528711, 2466948901, 113926993, 3758326383, 338241895, 168717936, 666307205, 1188179964, 773529912, 1546045734, 1294757372, 1522805485, 1396182291, 2643833823, 1695183700, 2343527390, 1986661051, 1014477480, 2177026350, 1206759142, 2456956037, 344077627, 2730485921, 1290863460, 2820302411, 3158454273, 3259730800, 3505952657, 3345764771, 106217008, 3516065817, 3606008344, 3600352804, 1432725776, 4094571909, 1467031594, 275423344, 851169720, 430227734, 3100823752, 506948616, 1363258195, 659060556, 3750685593, 883997877, 3785050280, 958139571, 3318307427, 1322822218, 3812723403, 1537002063, 2003034995, 1747873779, 3602036899, 1955562222, 1575990012, 2024104815, 1125592928, 2227730452, 2716904306, 2361852424, 442776044, 2428436474, 593698344, 2756734187, 3733110249, 3204031479, 2999351573, 3329325298, 3815920427, 3391569614, 3928383900, 3515267271, 566280711, 3940187606, 3454069534, 4118630271, 4000239992, 116418474, 1914138554, 174292421, 2731055270, 289380356, 3203993006, 460393269, 320620315, 685471733, 587496836, 852142971, 1086792851, 1017036298, 365543100, 1126000580, 2618297676, 1288033470, 3409855158, 1501505948, 4234509866, 1607167915, 987167468, 1816402316, 1246189591 }
local H0 = { 1779033703, 4089235720, 3144134277, 2227873595, 1013904242, 4271175723, 2773480762, 1595750129, 1359893119, 2917565137, 2600822924, 725511199, 528734635, 4215389547, 1541459225, 327033209 }

-- Field arithmetic ---------------------------------------------------------------

local function Set(r, a)
  local i
  for i = 0, 15 do r[i] = a[i] end
end

local function A(o, a, b)
  local i
  for i = 0, 15 do o[i] = a[i] + b[i] end
end

local function Z(o, a, b)
  local i
  for i = 0, 15 do o[i] = a[i] - b[i] end
end

-- o = a * b, unrolled (generated), then two carries. o may be a or b.
local function M(o, a, b)
  local a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15 = a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15]
  local b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12, b13, b14, b15 = b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
  local t0 = a0 * b0 + 38 * (a1 * b15 + a2 * b14 + a3 * b13 + a4 * b12 + a5 * b11 + a6 * b10 + a7 * b9 + a8 * b8 + a9 * b7 + a10 * b6 + a11 * b5 + a12 * b4 + a13 * b3 + a14 * b2 + a15 * b1)
  local t1 = a0 * b1 + a1 * b0 + 38 * (a2 * b15 + a3 * b14 + a4 * b13 + a5 * b12 + a6 * b11 + a7 * b10 + a8 * b9 + a9 * b8 + a10 * b7 + a11 * b6 + a12 * b5 + a13 * b4 + a14 * b3 + a15 * b2)
  local t2 = a0 * b2 + a1 * b1 + a2 * b0 + 38 * (a3 * b15 + a4 * b14 + a5 * b13 + a6 * b12 + a7 * b11 + a8 * b10 + a9 * b9 + a10 * b8 + a11 * b7 + a12 * b6 + a13 * b5 + a14 * b4 + a15 * b3)
  local t3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0 + 38 * (a4 * b15 + a5 * b14 + a6 * b13 + a7 * b12 + a8 * b11 + a9 * b10 + a10 * b9 + a11 * b8 + a12 * b7 + a13 * b6 + a14 * b5 + a15 * b4)
  local t4 = a0 * b4 + a1 * b3 + a2 * b2 + a3 * b1 + a4 * b0 + 38 * (a5 * b15 + a6 * b14 + a7 * b13 + a8 * b12 + a9 * b11 + a10 * b10 + a11 * b9 + a12 * b8 + a13 * b7 + a14 * b6 + a15 * b5)
  local t5 = a0 * b5 + a1 * b4 + a2 * b3 + a3 * b2 + a4 * b1 + a5 * b0 + 38 * (a6 * b15 + a7 * b14 + a8 * b13 + a9 * b12 + a10 * b11 + a11 * b10 + a12 * b9 + a13 * b8 + a14 * b7 + a15 * b6)
  local t6 = a0 * b6 + a1 * b5 + a2 * b4 + a3 * b3 + a4 * b2 + a5 * b1 + a6 * b0 + 38 * (a7 * b15 + a8 * b14 + a9 * b13 + a10 * b12 + a11 * b11 + a12 * b10 + a13 * b9 + a14 * b8 + a15 * b7)
  local t7 = a0 * b7 + a1 * b6 + a2 * b5 + a3 * b4 + a4 * b3 + a5 * b2 + a6 * b1 + a7 * b0 + 38 * (a8 * b15 + a9 * b14 + a10 * b13 + a11 * b12 + a12 * b11 + a13 * b10 + a14 * b9 + a15 * b8)
  local t8 = a0 * b8 + a1 * b7 + a2 * b6 + a3 * b5 + a4 * b4 + a5 * b3 + a6 * b2 + a7 * b1 + a8 * b0 + 38 * (a9 * b15 + a10 * b14 + a11 * b13 + a12 * b12 + a13 * b11 + a14 * b10 + a15 * b9)
  local t9 = a0 * b9 + a1 * b8 + a2 * b7 + a3 * b6 + a4 * b5 + a5 * b4 + a6 * b3 + a7 * b2 + a8 * b1 + a9 * b0 + 38 * (a10 * b15 + a11 * b14 + a12 * b13 + a13 * b12 + a14 * b11 + a15 * b10)
  local t10 = a0 * b10 + a1 * b9 + a2 * b8 + a3 * b7 + a4 * b6 + a5 * b5 + a6 * b4 + a7 * b3 + a8 * b2 + a9 * b1 + a10 * b0 + 38 * (a11 * b15 + a12 * b14 + a13 * b13 + a14 * b12 + a15 * b11)
  local t11 = a0 * b11 + a1 * b10 + a2 * b9 + a3 * b8 + a4 * b7 + a5 * b6 + a6 * b5 + a7 * b4 + a8 * b3 + a9 * b2 + a10 * b1 + a11 * b0 + 38 * (a12 * b15 + a13 * b14 + a14 * b13 + a15 * b12)
  local t12 = a0 * b12 + a1 * b11 + a2 * b10 + a3 * b9 + a4 * b8 + a5 * b7 + a6 * b6 + a7 * b5 + a8 * b4 + a9 * b3 + a10 * b2 + a11 * b1 + a12 * b0 + 38 * (a13 * b15 + a14 * b14 + a15 * b13)
  local t13 = a0 * b13 + a1 * b12 + a2 * b11 + a3 * b10 + a4 * b9 + a5 * b8 + a6 * b7 + a7 * b6 + a8 * b5 + a9 * b4 + a10 * b3 + a11 * b2 + a12 * b1 + a13 * b0 + 38 * (a14 * b15 + a15 * b14)
  local t14 = a0 * b14 + a1 * b13 + a2 * b12 + a3 * b11 + a4 * b10 + a5 * b9 + a6 * b8 + a7 * b7 + a8 * b6 + a9 * b5 + a10 * b4 + a11 * b3 + a12 * b2 + a13 * b1 + a14 * b0 + 38 * (a15 * b15)
  local t15 = a0 * b15 + a1 * b14 + a2 * b13 + a3 * b12 + a4 * b11 + a5 * b10 + a6 * b9 + a7 * b8 + a8 * b7 + a9 * b6 + a10 * b5 + a11 * b4 + a12 * b3 + a13 * b2 + a14 * b1 + a15 * b0
  local c, v = 1
  v = t0 + c + 65535; c = floor(v / 65536); t0 = v - c * 65536
  v = t1 + c + 65535; c = floor(v / 65536); t1 = v - c * 65536
  v = t2 + c + 65535; c = floor(v / 65536); t2 = v - c * 65536
  v = t3 + c + 65535; c = floor(v / 65536); t3 = v - c * 65536
  v = t4 + c + 65535; c = floor(v / 65536); t4 = v - c * 65536
  v = t5 + c + 65535; c = floor(v / 65536); t5 = v - c * 65536
  v = t6 + c + 65535; c = floor(v / 65536); t6 = v - c * 65536
  v = t7 + c + 65535; c = floor(v / 65536); t7 = v - c * 65536
  v = t8 + c + 65535; c = floor(v / 65536); t8 = v - c * 65536
  v = t9 + c + 65535; c = floor(v / 65536); t9 = v - c * 65536
  v = t10 + c + 65535; c = floor(v / 65536); t10 = v - c * 65536
  v = t11 + c + 65535; c = floor(v / 65536); t11 = v - c * 65536
  v = t12 + c + 65535; c = floor(v / 65536); t12 = v - c * 65536
  v = t13 + c + 65535; c = floor(v / 65536); t13 = v - c * 65536
  v = t14 + c + 65535; c = floor(v / 65536); t14 = v - c * 65536
  v = t15 + c + 65535; c = floor(v / 65536); t15 = v - c * 65536
  t0 = t0 + c - 1 + 37 * (c - 1)
  local c, v = 1
  v = t0 + c + 65535; c = floor(v / 65536); t0 = v - c * 65536
  v = t1 + c + 65535; c = floor(v / 65536); t1 = v - c * 65536
  v = t2 + c + 65535; c = floor(v / 65536); t2 = v - c * 65536
  v = t3 + c + 65535; c = floor(v / 65536); t3 = v - c * 65536
  v = t4 + c + 65535; c = floor(v / 65536); t4 = v - c * 65536
  v = t5 + c + 65535; c = floor(v / 65536); t5 = v - c * 65536
  v = t6 + c + 65535; c = floor(v / 65536); t6 = v - c * 65536
  v = t7 + c + 65535; c = floor(v / 65536); t7 = v - c * 65536
  v = t8 + c + 65535; c = floor(v / 65536); t8 = v - c * 65536
  v = t9 + c + 65535; c = floor(v / 65536); t9 = v - c * 65536
  v = t10 + c + 65535; c = floor(v / 65536); t10 = v - c * 65536
  v = t11 + c + 65535; c = floor(v / 65536); t11 = v - c * 65536
  v = t12 + c + 65535; c = floor(v / 65536); t12 = v - c * 65536
  v = t13 + c + 65535; c = floor(v / 65536); t13 = v - c * 65536
  v = t14 + c + 65535; c = floor(v / 65536); t14 = v - c * 65536
  v = t15 + c + 65535; c = floor(v / 65536); t15 = v - c * 65536
  t0 = t0 + c - 1 + 37 * (c - 1)
  o[0] = t0; o[1] = t1; o[2] = t2; o[3] = t3; o[4] = t4; o[5] = t5; o[6] = t6; o[7] = t7; o[8] = t8; o[9] = t9; o[10] = t10; o[11] = t11; o[12] = t12; o[13] = t13; o[14] = t14; o[15] = t15
end

local function S(o, a)
  M(o, a, a)
end

local function Car(o)
  local c = 1
  local i
  for i = 0, 15 do
    local v = o[i] + c + 65535
    c = floor(v / 65536)
    o[i] = v - c * 65536
  end
  o[0] = o[0] + c - 1 + 37 * (c - 1)
end

local PT, PM = Gf(), Gf()

-- 32 bytes (index 0 to 31), little-endian, fully reduced modulo 2^255 - 19.
local function Pack25519(out, n)
  local t, m = PT, PM
  local i, j
  for i = 0, 15 do t[i] = n[i] end
  Car(t)
  Car(t)
  Car(t)
  for j = 1, 2 do
    m[0] = t[0] - 65517
    for i = 1, 14 do
      local borrow = 0
      if m[i - 1] < 0 then
        borrow = 1
        m[i - 1] = m[i - 1] + 65536
      end
      m[i] = t[i] - 65535 - borrow
    end
    local borrow = 0
    if m[14] < 0 then
      borrow = 1
      m[14] = m[14] + 65536
    end
    m[15] = t[15] - 32767 - borrow
    if m[15] >= 0 then
      -- t >= p: keep t - p.
      t, m = m, t
    end
  end
  for i = 0, 15 do
    local hi = floor(t[i] / 256)
    out[2 * i] = t[i] - hi * 256
    out[2 * i + 1] = hi
  end
  -- Keep the module temporaries in place whichever table holds the result.
  PT, PM = t, m
end

local function Unpack25519(o, n)
  local i
  for i = 0, 15 do o[i] = n[2 * i] + n[2 * i + 1] * 256 end
  o[15] = Mod(o[15], 32768)
end

local NA, NB = {}, {}

local function Neq(a, b)
  Pack25519(NA, a)
  Pack25519(NB, b)
  local i
  for i = 0, 31 do
    if NA[i] ~= NB[i] then return true end
  end
  return false
end

local function Par(a)
  Pack25519(NA, a)
  return Mod(NA[0], 2)
end

local function Inv25519(o, i)
  local c = Gf()
  Set(c, i)
  local a
  for a = 253, 0, -1 do
    S(c, c)
    if a ~= 2 and a ~= 4 then M(c, c, i) end
  end
  Set(o, c)
end

local function Pow2523(o, i)
  local c = Gf()
  Set(c, i)
  local a
  for a = 250, 0, -1 do
    S(c, c)
    if a ~= 1 then M(c, c, i) end
  end
  Set(o, c)
end

-- Points: extended coordinates { [1] = X, [2] = Y, [3] = Z, [4] = T } ----------------

local function Point()
  return { Gf(), Gf(), Gf(), Gf() }
end

local function SetPoint(r, p)
  Set(r[1], p[1])
  Set(r[2], p[2])
  Set(r[3], p[3])
  Set(r[4], p[4])
end

local function Identity(r)
  Set(r[1], GF0)
  Set(r[2], GF1)
  Set(r[3], GF1)
  Set(r[4], GF0)
end

local TA, TB, TC, TD, TE, TF, TG, TH, TT = Gf(), Gf(), Gf(), Gf(), Gf(), Gf(), Gf(), Gf(), Gf()

-- p = p + q (unified formula, also a doubling when q is p).
local function Add(p, q)
  local a, b, c, d, e, f, g, h, t = TA, TB, TC, TD, TE, TF, TG, TH, TT
  Z(a, p[2], p[1])
  Z(t, q[2], q[1])
  M(a, a, t)
  A(b, p[1], p[2])
  A(t, q[1], q[2])
  M(b, b, t)
  M(c, p[4], q[4])
  M(c, c, D2)
  M(d, p[3], q[3])
  A(d, d, d)
  Z(e, b, a)
  Z(f, d, c)
  A(g, d, c)
  A(h, b, a)
  M(p[1], e, f)
  M(p[2], h, g)
  M(p[3], g, f)
  M(p[4], e, h)
end

local function Pack(out, p)
  local tx, ty, zi = Gf(), Gf(), Gf()
  Inv25519(zi, p[3])
  M(tx, p[1], zi)
  M(ty, p[2], zi)
  Pack25519(out, ty)
  out[31] = out[31] + Par(tx) * 128
end

-- r = -A from its 32-byte encoding; false when it is not a curve point.
local function UnpackNeg(r, p)
  local t, chk, num, den, den2, den4, den6 = Gf(), Gf(), Gf(), Gf(), Gf(), Gf(), Gf()
  Set(r[3], GF1)
  Unpack25519(r[2], p)
  S(num, r[2])
  M(den, num, D)
  Z(num, num, r[3])
  A(den, r[3], den)
  S(den2, den)
  S(den4, den2)
  M(den6, den4, den2)
  M(t, den6, num)
  M(t, t, den)
  Pow2523(t, t)
  M(t, t, num)
  M(t, t, den)
  M(t, t, den)
  M(r[1], t, den)
  S(chk, r[1])
  M(chk, chk, den)
  if Neq(chk, num) then M(r[1], r[1], SQRTM1) end
  S(chk, r[1])
  M(chk, chk, den)
  if Neq(chk, num) then return false end
  if Par(r[1]) == floor(p[31] / 128) then Z(r[1], GF0, r[1]) end
  M(r[4], r[1], r[2])
  return true
end

-- Multiples 0 to 15 of a point.
local function Multiples(p, pause)
  local list = {}
  list[0] = Point()
  Identity(list[0])
  local j
  for j = 1, 15 do
    list[j] = Point()
    SetPoint(list[j], list[j - 1])
    Add(list[j], p)
    if pause then pause() end
  end
  return list
end

local baseMultiples

local function BaseMultiples()
  if not baseMultiples then
    local b = Point()
    Set(b[1], BX)
    Set(b[2], BY)
    Set(b[3], GF1)
    M(b[4], BX, BY)
    baseMultiples = Multiples(b)
  end
  return baseMultiples
end

local function Nibble(s, i)
  local byte = s[floor(i / 2)]
  if Mod(i, 2) == 0 then return Mod(byte, 16) end
  return floor(byte / 16)
end

-- SHA-512 on 32-bit halves --------------------------------------------------------

local POW = {}
do
  local i
  POW[0] = 1
  for i = 1, 32 do POW[i] = POW[i - 1] * 2 end
end

local function Xor(a, b)
  if a >= I31 then a = a - U32 end
  if b >= I31 then b = b - U32 end
  local r = bit.bxor(a, b)
  if r < 0 then r = r + U32 end
  return r
end

-- a + b = (a xor b) + 2 (a and b)
local function And(a, b)
  return (a + b - Xor(a, b)) / 2
end

local function Rotr(h, l, n)
  if n >= 32 then
    h, l = l, h
    n = n - 32
  end
  if n == 0 then return h, l end
  local p, q = POW[n], POW[32 - n]
  local hh = floor(h / p)
  local lh = floor(l / p)
  return hh + (l - lh * p) * q, lh + (h - hh * p) * q
end

local function Shr(h, l, n)
  local p, q = POW[n], POW[32 - n]
  local hh = floor(h / p)
  return hh, floor(l / p) + (h - hh * p) * q
end

local function Xor3(ah, al, bh, bl, ch, cl)
  return Xor(Xor(ah, bh), ch), Xor(Xor(al, bl), cl)
end

local function BigSigma0(h, l)
  local ah, al = Rotr(h, l, 28)
  local bh, bl = Rotr(h, l, 34)
  local ch, cl = Rotr(h, l, 39)
  return Xor3(ah, al, bh, bl, ch, cl)
end

local function BigSigma1(h, l)
  local ah, al = Rotr(h, l, 14)
  local bh, bl = Rotr(h, l, 18)
  local ch, cl = Rotr(h, l, 41)
  return Xor3(ah, al, bh, bl, ch, cl)
end

local function SmallSigma0(h, l)
  local ah, al = Rotr(h, l, 1)
  local bh, bl = Rotr(h, l, 8)
  local ch, cl = Shr(h, l, 7)
  return Xor3(ah, al, bh, bl, ch, cl)
end

local function SmallSigma1(h, l)
  local ah, al = Rotr(h, l, 19)
  local bh, bl = Rotr(h, l, 61)
  local ch, cl = Shr(h, l, 6)
  return Xor3(ah, al, bh, bl, ch, cl)
end

-- Sum of 64-bit values given as hi, lo lists (at most 5 terms: exact).
local function Sum(hs, ls)
  local h, l = 0, 0
  local i
  for i = 1, 5 do
    if not ls[i] then break end
    h = h + hs[i]
    l = l + ls[i]
  end
  local c = floor(l / U32)
  l = l - c * U32
  h = h + c
  return h - floor(h / U32) * U32, l
end

-- bytes: 0-based list of byte values; returns the 64-byte digest, 0-based.
local function Sha512(bytes, n)
  local msg = {}
  local i, t
  for i = 0, n - 1 do msg[i] = bytes[i] end
  msg[n] = 128
  local total = n + 1
  while Mod(total, 128) ~= 112 do
    msg[total] = 0
    total = total + 1
  end
  local bits = n * 8
  for i = 15, 0, -1 do
    msg[total + i] = Mod(bits, 256)
    bits = floor(bits / 256)
  end
  total = total + 16
  local H = {}
  for i = 1, 16 do H[i] = H0[i] end
  local Wh, Wl = {}, {}
  local start
  for start = 0, total - 1, 128 do
    for t = 0, 15 do
      local o = start + t * 8
      Wh[t] = ((msg[o] * 256 + msg[o + 1]) * 256 + msg[o + 2]) * 256 + msg[o + 3]
      Wl[t] = ((msg[o + 4] * 256 + msg[o + 5]) * 256 + msg[o + 6]) * 256 + msg[o + 7]
    end
    for t = 16, 79 do
      local s0h, s0l = SmallSigma0(Wh[t - 15], Wl[t - 15])
      local s1h, s1l = SmallSigma1(Wh[t - 2], Wl[t - 2])
      Wh[t], Wl[t] = Sum({ Wh[t - 16], s0h, Wh[t - 7], s1h }, { Wl[t - 16], s0l, Wl[t - 7], s1l })
    end
    local ah, al, bh, bl, ch, cl, dh, dl = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    local eh, el, fh, fl, gh, gl, hh, hl = H[9], H[10], H[11], H[12], H[13], H[14], H[15], H[16]
    for t = 0, 79 do
      local s1h, s1l = BigSigma1(eh, el)
      -- Ch(e, f, g) = g xor (e and (f xor g))
      local chh = Xor(gh, And(eh, Xor(fh, gh)))
      local chl = Xor(gl, And(el, Xor(fl, gl)))
      local t1h, t1l = Sum({ hh, s1h, chh, K[2 * t + 1], Wh[t] }, { hl, s1l, chl, K[2 * t + 2], Wl[t] })
      local s0h, s0l = BigSigma0(ah, al)
      -- Maj(a, b, c) = (a and b) xor (c and (a xor b))
      local mjh = Xor(And(ah, bh), And(ch, Xor(ah, bh)))
      local mjl = Xor(And(al, bl), And(cl, Xor(al, bl)))
      local t2h, t2l = Sum({ s0h, mjh }, { s0l, mjl })
      hh, hl = gh, gl
      gh, gl = fh, fl
      fh, fl = eh, el
      eh, el = Sum({ dh, t1h }, { dl, t1l })
      dh, dl = ch, cl
      ch, cl = bh, bl
      bh, bl = ah, al
      ah, al = Sum({ t1h, t2h }, { t1l, t2l })
    end
    local v = { ah, al, bh, bl, ch, cl, dh, dl, eh, el, fh, fl, gh, gl, hh, hl }
    for i = 1, 15, 2 do H[i], H[i + 1] = Sum({ H[i], v[i] }, { H[i + 1], v[i + 1] }) end
  end
  local out = {}
  for i = 0, 15 do
    local word = H[i + 1]
    out[i * 4 + 3] = Mod(word, 256)
    word = floor(word / 256)
    out[i * 4 + 2] = Mod(word, 256)
    word = floor(word / 256)
    out[i * 4 + 1] = Mod(word, 256)
    out[i * 4] = floor(word / 256)
  end
  return out
end

Ed25519.Sha512 = Sha512

-- Scalars modulo L ----------------------------------------------------------------

-- r = x (64 bytes, little-endian) mod L, as 32 bytes.
local function ModL(r, x)
  local carry, i, j, k
  for i = 63, 32, -1 do
    carry = 0
    j = i - 32
    k = i - 12
    while j < k do
      x[j] = x[j] + carry - 16 * x[i] * L[j - (i - 32) + 1]
      carry = floor((x[j] + 128) / 256)
      x[j] = x[j] - carry * 256
      j = j + 1
    end
    x[j] = x[j] + carry
    x[i] = 0
  end
  carry = 0
  for j = 0, 31 do
    x[j] = x[j] + carry - floor(x[31] / 16) * L[j + 1]
    carry = floor(x[j] / 256)
    x[j] = x[j] - carry * 256
  end
  for j = 0, 31 do x[j] = x[j] - carry * L[j + 1] end
  x[32] = 0
  for i = 0, 31 do
    local hi = floor(x[i] / 256)
    x[i + 1] = x[i + 1] + hi
    r[i] = x[i] - hi * 256
  end
end

-- s < L, both 32 bytes little-endian (RFC 8032: no malleable signature).
local function BelowL(s)
  local i
  for i = 31, 0, -1 do
    if s[i] < L[i + 1] then return true end
    if s[i] > L[i + 1] then return false end
  end
  return false
end

-- Encodings -----------------------------------------------------------------------

local HEX = {}
do
  local i
  for i = 0, 9 do HEX[string.byte("0") + i] = i end
  for i = 0, 5 do HEX[string.byte("a") + i] = 10 + i end
end

-- 64 lower-case hex digits to 32 bytes (0-based), or nil.
function Ed25519.FromHex(text)
  if type(text) ~= "string" or string.len(text) ~= 64 then return nil end
  local out = {}
  local i
  for i = 0, 31 do
    local h = HEX[string.byte(text, 2 * i + 1)]
    local l = HEX[string.byte(text, 2 * i + 2)]
    if not h or not l then return nil end
    out[i] = h * 16 + l
  end
  return out
end

local B64 = {}
do
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local i
  for i = 1, 64 do B64[string.byte(alphabet, i)] = i - 1 end
end

-- 86 characters of unpadded base64url to 64 bytes (0-based), or nil; the 4
-- unused bits must be zero, so that one signature has one encoding.
function Ed25519.FromBase64Url(text)
  if type(text) ~= "string" or string.len(text) ~= 86 then return nil end
  local out = {}
  local acc, bits, n = 0, 0, 0
  local i
  for i = 1, 86 do
    local v = B64[string.byte(text, i)]
    if not v then return nil end
    acc = acc * 64 + v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      local byte = floor(acc / POW[bits])
      out[n] = byte
      n = n + 1
      acc = acc - byte * POW[bits]
    end
  end
  if n ~= 64 or acc ~= 0 then return nil end
  return out
end

-- Verification ----------------------------------------------------------------------

-- True when signature (64 bytes) is publicKey's (32 bytes) Ed25519 signature
-- of message (a string). pause, when given, is called between point additions.
function Ed25519.Verify(publicKey, message, signature, pause)
  if type(publicKey) ~= "table" or type(signature) ~= "table" or type(message) ~= "string" then return false end
  local s = {}
  local i
  for i = 0, 31 do s[i] = signature[32 + i] end
  if not BelowL(s) then return false end
  local negA = Point()
  if not UnpackNeg(negA, publicKey) then return false end
  if pause then pause() end

  -- h = SHA-512(R || A || message) mod L
  local bytes = {}
  for i = 0, 31 do
    bytes[i] = signature[i]
    bytes[32 + i] = publicKey[i]
  end
  local n = string.len(message)
  for i = 1, n do bytes[63 + i] = string.byte(message, i) end
  local digest = Sha512(bytes, 64 + n)
  local h = {}
  ModL(h, digest)
  if pause then pause() end

  -- P = [h](-A) + [s]B, 4-bit windows on both scalars.
  local tableA = Multiples(negA, pause)
  local tableB = BaseMultiples()
  local p = Point()
  Identity(p)
  for i = 63, 0, -1 do
    if i < 63 then
      local k
      for k = 1, 4 do
        Add(p, p)
        if pause then pause() end
      end
    end
    local nh, ns = Nibble(h, i), Nibble(s, i)
    if nh > 0 then Add(p, tableA[nh]) end
    if ns > 0 then Add(p, tableB[ns]) end
    if pause then pause() end
  end
  local out = {}
  Pack(out, p)
  for i = 0, 31 do
    if out[i] ~= signature[i] then return false end
  end
  return true
end
