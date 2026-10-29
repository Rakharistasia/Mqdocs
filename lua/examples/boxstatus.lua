--[[
    boxstatus.lua - live Discord status card for a group of boxes.

    Run on every box:       /lua run boxstatus
    Run on ONE box (hub):   /lua run boxstatus hub

    Every box publishes a snapshot of itself over actors every few seconds. The hub collects them and keeps
    one Discord message per few boxes up to date through a webhook (edit in place, no spam). It also posts
    a separate, pingable message when a box dies, goes silent, or stops running RGMercs.

    Binds:  /boxstatus stop | post | forget <name>
]]

local mq = require('mq')
local actors = require('actors')
local PackageMan = require('mq/PackageMan')
local curl = PackageMan.Require('lua-curl', 'lcurl')
local cjson = PackageMan.Require('lua-cjson', 'cjson')

local CONFIG_FILE = 'boxstatus.lua'
local STATE_FILE = 'boxstatus_state.lua'
local PUBLISH_EVERY = 5       -- seconds between snapshots from each box
local RATE_WINDOW = 3600      -- seconds of history used for XP/hr
local RATE_MIN_SPAN = 120     -- seconds of history needed before showing a rate
local BOXES_PER_MESSAGE = 6   -- Discord allows 10 embeds and 6000 chars per message

local DEFAULTS = {
    webhook_url = '',         -- Discord channel > Integrations > Webhooks > Copy Webhook URL
    mention = '',             -- optional Discord user ID to ping on alerts
    title = 'Box Status',
    interval = 30,            -- seconds between card updates (hub only)
    stale_after = 45,         -- seconds without a snapshot before a box is reported silent
    low_hp = 30,              -- card turns yellow below this HP%
}

local COLOR = { ok = 0x57F287, warn = 0xFEE75C, bad = 0xED4245 }

local isHub = (({ ... })[1] or ''):lower() == 'hub'
local running = true
local cfg = {}
local state = { url = '', ids = {} }
local boxes = {}              -- hub only: name -> { snap = {...}, recv = os.time() }
local alerted = {}            -- hub only: name -> alert kind currently active
local samples = {}
local retryAt = 0

local function log(fmt, ...)
    print(('[boxstatus] ' .. fmt):format(...))
end

local function loadTable(file)
    local chunk = loadfile(mq.configDir .. '/' .. file)
    if not chunk then return nil end
    local ok, tbl = pcall(chunk)
    return ok and type(tbl) == 'table' and tbl or nil
end

local function loadConfig()
    local saved = loadTable(CONFIG_FILE)
    if not saved then
        mq.pickle(CONFIG_FILE, DEFAULTS)
        return false
    end
    for k, v in pairs(DEFAULTS) do cfg[k] = saved[k] ~= nil and saved[k] or v end
    return cfg.webhook_url ~= ''
end

local function saveState()
    mq.pickle(STATE_FILE, state)
end

------------------------------------------------------------------------------------------------ snapshot

local function rgmercsStatus()
    local ok, status = pcall(function() return mq.TLO.Lua.Script('rgmercs').Status() end)
    if not ok or not status then return 'off' end
    local paused = false
    pcall(function() paused = mq.TLO.RGMercs.Paused() == true end)
    return (paused or status == 'PAUSED') and 'paused' or 'running'
end

local function updateRates(now, xp, aa)
    samples[#samples + 1] = { t = now, xp = xp, aa = aa }
    while #samples > 2 and now - samples[2].t > RATE_WINDOW do table.remove(samples, 1) end
    local first, last = samples[1], samples[#samples]
    local span = last.t - first.t
    if span < RATE_MIN_SPAN then return nil, nil end
    local hours = span / 3600
    return (last.xp - first.xp) / hours, (last.aa - first.aa) / hours
end

local function snapshot()
    local me = mq.TLO.Me
    local now = os.time()
    local xp = me.Level() * 100 + (me.PctExp() or 0)
    local aa = (me.AAPoints() or 0) + (me.AAPointsSpent() or 0) + (me.PctAAExp() or 0) / 100
    local xpHr, aaHr = updateRates(now, xp, aa)
    local target = mq.TLO.Target.CleanName()
    return {
        name = me.CleanName(),
        class = me.Class.ShortName(),
        level = me.Level(),
        zone = mq.TLO.Zone.ShortName(),
        hp = me.PctHPs(),
        state = me.State(),
        combat = me.CombatState(),
        dead = me.Hovering() == true,
        target = target,
        xtargets = me.XTarget() or 0,
        rg = rgmercsStatus(),
        xpHr = xpHr,
        aaHr = aaHr,
    }
end

------------------------------------------------------------------------------------------------ http

local function request(method, url, body)
    local out = {}
    local opts = {
        url = url,
        httpheader = { 'Content-Type: application/json' },
        writefunction = function(chunk) out[#out + 1] = chunk end,
        timeout = 5,
        connecttimeout = 3,
    }
    if method == 'POST' then
        opts.post = true
        opts.postfields = body
    else
        opts.customrequest = method
        opts.postfields = body
    end
    local easy = curl.easy(opts)
    local ok, err = pcall(easy.perform, easy)
    local code = ok and easy:getinfo_response_code() or 0
    easy:close()
    return code, table.concat(out), err
end

local function checkRateLimit(code, body)
    if code ~= 429 then return end
    local ok, decoded = pcall(cjson.decode, body)
    local wait = ok and decoded and decoded.retry_after or 5
    retryAt = os.time() + math.ceil(wait)
    log('Rate limited by Discord, pausing %ds', wait)
end

local function sendMessage(payload)
    local code, body, err = request('POST', cfg.webhook_url .. '?wait=true', cjson.encode(payload))
    checkRateLimit(code, body)
    if code ~= 200 then
        log('Webhook POST failed (%s)%s', tostring(code), err and (': ' .. tostring(err)) or '')
        return nil
    end
    local ok, decoded = pcall(cjson.decode, body)
    return ok and decoded and decoded.id or nil
end

local function editMessage(id, payload)
    local code, body = request('PATCH', ('%s/messages/%s'):format(cfg.webhook_url, id), cjson.encode(payload))
    checkRateLimit(code, body)
    return code
end

local function deleteMessage(id)
    request('DELETE', ('%s/messages/%s'):format(cfg.webhook_url, id))
end

------------------------------------------------------------------------------------------------ card

local function bar(pct)
    pct = math.max(0, math.min(100, pct or 0))
    local filled = math.floor(pct / 10 + 0.5)
    return ('%s%s %d%%'):format(('█'):rep(filled), ('░'):rep(10 - filled), pct)
end

local function perHour(value, suffix)
    if value == nil then return '—' end
    return ('%s%.2f%s'):format(value >= 0 and '+' or '', value, suffix)
end

local function boxHealth(entry, now)
    local snap = entry.snap
    if now - entry.recv > cfg.stale_after then return 'bad', 'silent' end
    if snap.dead then return 'bad', 'dead' end
    if snap.rg == 'off' then return 'bad', 'rgmercs off' end
    if snap.rg == 'paused' or (snap.hp or 100) < cfg.low_hp then return 'warn', nil end
    return 'ok', nil
end

local function buildEmbed(name, entry, now)
    local snap = entry.snap
    local health, reason = boxHealth(entry, now)
    local fields = {
        { name = 'HP', value = bar(snap.hp), inline = true },
    }
    fields[#fields + 1] = {
        name = 'Target',
        value = ('%s (%d xtar)'):format(snap.target or 'none', snap.xtargets or 0),
        inline = true,
    }
    fields[#fields + 1] = { name = 'RGMercs', value = snap.rg, inline = true }
    fields[#fields + 1] = {
        name = 'Rates',
        value = ('%s XP/hr · %s AA/hr'):format(perHour(snap.xpHr, '%'), perHour(snap.aaHr, '')),
        inline = true,
    }
    local status = snap.dead and 'DEAD' or (snap.combat or snap.state or '?')
    if reason == 'silent' then status = 'NO SIGNAL' end
    return {
        title = ('%s · L%s %s'):format(name, tostring(snap.level), snap.class or '?'),
        description = ('%s · %s\nUpdated <t:%d:R>'):format(snap.zone or '?', status, entry.recv),
        color = COLOR[health],
        fields = fields,
    }
end

local function sortedNames()
    local names = {}
    for name in pairs(boxes) do names[#names + 1] = name end
    table.sort(names)
    return names
end

local function buildPayloads(now)
    local names = sortedNames()
    local payloads = {}
    for i = 1, #names, BOXES_PER_MESSAGE do
        local embeds = {}
        for j = i, math.min(i + BOXES_PER_MESSAGE - 1, #names) do
            embeds[#embeds + 1] = buildEmbed(names[j], boxes[names[j]], now)
        end
        payloads[#payloads + 1] = {
            content = i == 1 and ('**%s** · %d boxes'):format(cfg.title, #names) or '',
            embeds = embeds,
        }
    end
    return payloads
end

local function updateCard()
    local now = os.time()
    if now < retryAt then return end
    local payloads = buildPayloads(now)
    for i, payload in ipairs(payloads) do
        local id = state.ids[i]
        if id and editMessage(id, payload) == 404 then id = nil end
        if not id then
            state.ids[i] = sendMessage(payload)
            saveState()
        end
    end
    for i, id in pairs(state.ids) do
        if i > #payloads then
            deleteMessage(id)
            state.ids[i] = nil
            saveState()
        end
    end
end

------------------------------------------------------------------------------------------------ alerts

local function checkAlerts()
    local now = os.time()
    for name, entry in pairs(boxes) do
        local health, reason = boxHealth(entry, now)
        local kind = health == 'bad' and reason or nil
        if kind and alerted[name] ~= kind then
            local ping = cfg.mention ~= '' and ('<@%s> '):format(cfg.mention) or ''
            sendMessage({
                content = ('%s🚨 **%s**: %s (%s)'):format(ping, name, kind, entry.snap.zone or '?'),
                allowed_mentions = cfg.mention ~= '' and { parse = { 'users' } } or nil,
            })
        end
        alerted[name] = kind
    end
end

------------------------------------------------------------------------------------------------ main

local actor
local function onMessage(message)
    if not isHub then return end
    local snap = message.content
    if type(snap) ~= 'table' or not snap.name then return end
    boxes[snap.name] = { snap = snap, recv = os.time() }
end

local function publish()
    local snap = snapshot()
    actor:send(snap)
    if isHub then boxes[snap.name] = { snap = snap, recv = os.time() } end
end

local function onCommand(cmd, arg)
    cmd = (cmd or ''):lower()
    if cmd == 'stop' then
        running = false
    elseif cmd == 'post' and isHub then
        updateCard()
    elseif cmd == 'forget' and arg then
        boxes[arg] = nil
        alerted[arg] = nil
        log('Forgot %s', arg)
    else
        log('/boxstatus stop | post | forget <name>')
    end
end

if isHub then
    if not loadConfig() then
        log('Edit %s/%s and set webhook_url, then run /lua run boxstatus hub again.', mq.configDir, CONFIG_FILE)
        return
    end
    local saved = loadTable(STATE_FILE)
    if saved and saved.url == cfg.webhook_url then state = saved end
    state.url = cfg.webhook_url
end

actor = actors.register('status', onMessage)
mq.bind('/boxstatus', onCommand)
log('Running as %s.', isHub and 'hub (posting to Discord)' or 'sender')

local lastPublish, lastPost = 0, 0
while running do
    local now = os.time()
    if mq.TLO.MacroQuest.GameState() == 'INGAME' and now - lastPublish >= PUBLISH_EVERY then
        lastPublish = now
        publish()
    end
    if isHub and now - lastPost >= cfg.interval then
        lastPost = now
        updateCard()
        checkAlerts()
    end
    mq.delay(1000)
end

actor:unregister()
log('Stopped.')
