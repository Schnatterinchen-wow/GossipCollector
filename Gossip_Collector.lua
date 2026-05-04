--[[
  Gossip_Collector — Turtle WoW + SuperWoW (1.12 / Lua 5.1)

  On GOSSIP_SHOW, records one row per unique (npc GUID + gossip body hash):
    guid      — from UnitExists("npc") second return (SuperWoW; creature GUID 0xF130…)
    entryId   — npc template id decoded from that GUID (same packing as NPCTracker)
    name      — UnitName("npc")
    text      — GetGossipText() (server body text, incl. |c…|r, $B, $N, etc.)

  Persistence: Blizzard writes SavedVariables to
    WTF\Account\<account>\SavedVariables\Gossip_Collector.lua

  Options (SavedVariables): GossipCollectorDB.chatMessages — chat tips/errors (default on).
  Commands: /gossipcollector or /gc — help | on | off | toggle | status

  Original hash-based collector: Platine (retail). Rewritten for vanilla + TwOW data needs.
]]

GossipCollectorDB = GossipCollectorDB or {}
GossipCollectorDB.version = GossipCollectorDB.version or 1
GossipCollectorDB.records = GossipCollectorDB.records or {}
GossipCollectorDB._index = GossipCollectorDB._index or {}
-- nil or true = show login + capture errors; false = silent (capture still runs)
if GossipCollectorDB.chatMessages == nil then
  GossipCollectorDB.chatMessages = true
end

local function chatEnabled()
  return GossipCollectorDB.chatMessages ~= false
end

local function chatMsg(text)
  if chatEnabled() then
    DEFAULT_CHAT_FRAME:AddMessage(text)
  end
end

-- ——— 32-bit string hash (Platine; dedup key) ———
local function StringHash(text)
  if not text or text == "" then
    return 0
  end
  local counter = 1
  local pomoc = 0
  local dlug = string.len(text)
  for i = 1, dlug, 3 do
    counter = math.fmod(counter * 8161, 4294967279)
    pomoc = (string.byte(text, i) * 16776193)
    counter = counter + pomoc
    pomoc = ((string.byte(text, i + 1) or (dlug - i + 256)) * 8372226)
    counter = counter + pomoc
    pomoc = ((string.byte(text, i + 2) or (dlug - i + 256)) * 3932164)
    counter = counter + pomoc
  end
  return math.fmod(counter, 4294967291)
end

-- ——— GUID helpers (layout matches addon\NPCTracker\NPCTracker.lua) ———
local function NormalizeGuidKey(guid)
  if type(guid) ~= "string" or guid == "" then
    return nil
  end
  local g = string.gsub(guid, "%s+", "")
  g = string.upper(g)
  g = string.gsub(g, "^0X", "0x")
  return g
end

local function CreatureEntryFromGuid(guid)
  local g = NormalizeGuidKey(guid)
  if not g then
    return nil
  end
  g = string.gsub(g, "^0x", "")
  if string.len(g) ~= 16 then
    return nil
  end
  if string.sub(g, 1, 4) ~= "F130" then
    return nil
  end
  local hi = tonumber(string.sub(g, 1, 8), 16)
  local lo = tonumber(string.sub(g, 9, 16), 16)
  if not hi or not lo then
    return nil
  end
  local lowByte = hi - math.floor(hi / 256) * 256
  local highByte = math.floor(lo / 16777216)
  return lowByte * 256 + highByte
end

--- All-or-nothing: on any error, SavedVariables are not modified (no half-updated row/index).
local function captureGossip()
  local ok, err = pcall(function()
    if not UnitExists("npc") then
      return
    end

    local body = GetGossipText and GetGossipText() or nil
    if not body or body == "" then
      return
    end

    local name = UnitName("npc")
    if (not name or name == "") and GossipFrameNpcNameText then
      name = GossipFrameNpcNameText:GetText()
    end
    if not name or name == "" then
      return
    end

    local guid
    if SUPERWOW_VERSION then
      local _, g = UnitExists("npc")
      guid = NormalizeGuidKey(g)
    end

    local entryId = guid and CreatureEntryFromGuid(guid) or nil
    local h = StringHash(body)
    local dedupe = (guid or ("nonpc:" .. name)) .. "\1" .. tostring(h)

    if GossipCollectorDB._index[dedupe] then
      return
    end

    table.insert(GossipCollectorDB.records, {
      guid = guid,
      entryId = entryId,
      name = name,
      text = body,
      locale = GetLocale(),
      sessionTime = GetTime(),
    })
    GossipCollectorDB._index[dedupe] = true
  end)

  if not ok then
    chatMsg("|cffff4440Gossip-Collector|r capture error (data not saved this time): " .. tostring(err))
  end
end

local deferFrame = CreateFrame("Frame")
local gcFrame = CreateFrame("Frame")
gcFrame:RegisterEvent("GOSSIP_SHOW")
gcFrame:SetScript("OnEvent", function()
  if event ~= "GOSSIP_SHOW" then
    return
  end
  deferFrame:SetScript("OnUpdate", function()
    deferFrame:SetScript("OnUpdate", nil)
    captureGossip()
  end)
end)

local function trim(s)
  if not s then
    return ""
  end
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

local function slashHandler(msg)
  local a = string.lower(trim(msg or ""))
  if a == "" or a == "help" then
    chatMsg("|cffffff00Gossip-Collector|r /gc on | off | toggle | status")
    return
  end
  if a == "on" then
    GossipCollectorDB.chatMessages = true
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Gossip-Collector|r chat messages |cff00ff00ON|r.")
    return
  end
  if a == "off" or a == "quiet" then
    GossipCollectorDB.chatMessages = false
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00Gossip-Collector|r chat messages |cffff8888OFF|r (capture still runs).")
    return
  end
  if a == "toggle" then
    GossipCollectorDB.chatMessages = not chatEnabled()
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cffffff00Gossip-Collector|r chat messages "
        .. (chatEnabled() and "|cff00ff00ON|r." or "|cffff8888OFF|r.")
    )
    return
  end
  if a == "status" or a == "count" then
    local n = GossipCollectorDB.records and table.getn(GossipCollectorDB.records) or 0
    DEFAULT_CHAT_FRAME:AddMessage(
      "|cffffff00Gossip-Collector|r rows: |cffffffff"
        .. tostring(n)
        .. "|r | chat: "
        .. (chatEnabled() and "|cff00ff00on|r" or "|cffff8888off|r")
        .. " | SuperWoW: "
        .. (SUPERWOW_VERSION and "|cff00ff00yes|r" or "|cffff8888no|r")
    )
    return
  end
  chatMsg("|cffffff00Gossip-Collector|r unknown command. Try |cffffffff/gc help|r")
end

SLASH_GOSSIPCOLLECTOR1 = "/gossipcollector"
SLASH_GOSSIPCOLLECTOR2 = "/gc"
SlashCmdList["GOSSIPCOLLECTOR"] = slashHandler

if SUPERWOW_VERSION then
  chatMsg("|cffffff00Gossip-Collector|r Turtle: logging gossip to SavedVariables (SuperWoW GUID/entry id). |cffffcc00/gc help|r")
else
  chatMsg("|cffff8800Gossip-Collector|r SuperWoW not detected — guid/entryId will be empty; install SuperWoW for full rows. |cffffcc00/gc help|r")
end
