-- ==============================================
-- МИНИМАЛЬНЫЙ FAKE TRADE + SPAWNER (ИСПРАВЛЕННЫЙ)
-- Без лишних функций, только трейд и спавн
-- ==============================================

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')
local UserInputService = game:GetService('UserInputService')
local TweenService = game:GetService('TweenService')
local HttpService = game:GetService('HttpService')

-- Безопасный вызов setthreadidentity
pcall(function() setthreadidentity(2) end)

-- ==============================================
-- 1. ХУКИ ДЛЯ ФЕЙК-ПЛЕЕРОВ
-- ==============================================
local fakePlayerIds = {}
_G.fakePlayerIds = fakePlayerIds

task.spawn(function()
    task.wait(0.1)
    local success, SettingsHelper = pcall(function()
        return require(ReplicatedStorage:WaitForChild('Fsys')).load('SettingsHelper')
    end)
    if not success or not SettingsHelper then return end
    local original = SettingsHelper.get_setting_server
    SettingsHelper.get_setting_server = function(player, settingName, ...)
        if player and player.UserId and (fakePlayerIds[player.UserId] or not Players:GetPlayerByUserId(player.UserId)) then
            return false
        end
        local args = {...}
        local ok, result = pcall(function()
            return original(player, settingName, table.unpack(args))
        end)
        return ok and result or false
    end
end)

task.spawn(function()
    task.wait(0.1)
    local success, FamilyHelper = pcall(function()
        return require(ReplicatedStorage:WaitForChild('Fsys')).load('FamilyHelper')
    end)
    if not success or not FamilyHelper then return end
    local orig1 = FamilyHelper.are_friends_family
    local orig2 = FamilyHelper.is_my_friend_or_family
    FamilyHelper.are_friends_family = function(p1, p2)
        if p1 and p2 and (fakePlayerIds[p1.UserId] or fakePlayerIds[p2.UserId]) then return false end
        return orig1(p1, p2)
    end
    FamilyHelper.is_my_friend_or_family = function(p)
        if p and fakePlayerIds[p.UserId] then return false end
        return orig2(p)
    end
end)

-- ==============================================
-- 2. ЗАГРУЗКА МОДУЛЕЙ
-- ==============================================
local Fsys = require(ReplicatedStorage:WaitForChild('Fsys'))
local load = Fsys.load
local UIManager = load('UIManager')
local ClientData = load('ClientData')
local TableUtil = load('TableUtil')
local RouterClient = load('RouterClient')
local InventoryDB = load('InventoryDB')
local animationManager = load('AnimationManager')
local ColorThemeManager = load('ColorThemeManager')
local downloader = load('DownloadClient')

if UIManager.wait_for_initialization then UIManager:wait_for_initialization() else task.wait(2) end

local TradeApp = UIManager.apps.TradeApp
local BackpackApp = UIManager.apps.BackpackApp
local DialogApp = UIManager.apps.DialogApp
local HintApp = UIManager.apps.HintApp
local PlayerProfileApp = UIManager.apps.PlayerProfileApp
if not TradeApp then return end

local NegotiationFrame = Players.LocalPlayer.PlayerGui.TradeApp.Frame.NegotiationFrame
local function FriendHighlight(val)
    NegotiationFrame.FriendHighlight.Visible = val
    NegotiationFrame.FriendBorder.Visible = val
    local pf = NegotiationFrame.Header.PartnerFrame
    pf.NameLabel.FriendLabel.Visible = val
    local col = ColorThemeManager.lookup(val and 'background' or 'saturated')
    pf.ProfileIcon.ImageColor3 = col
    pf.NameLabel.TextColor3 = col
    pf.Icon.Visible = val
    pf.Icon.Image = 'rbxassetid://84667805159408'
end

-- ==============================================
-- 3. КОНФИГ И СОСТОЯНИЯ
-- ==============================================
local CONFIG = {
    PARTNER_NAME = 'SurenArmen',
    PARTNER_USER_ID = 987654321,
    AUTO_ACCEPT_DELAY = 0.5,
    AUTO_CONFIRM_DELAY = 0.3,
    SPECTATOR_COUNT = 0,
    AUTO_PARTNER = true,
    NEGOTIATION_LOCK = 5,
    CONFIRMATION_LOCK_PER_ITEM = 3,
    ADD_PET_REQUEST_DELAY = 1.6,
    SPAWN_FAKE_PLAYER_WITH_RANDOM_PET = false,
    FAKE_PLAYER_ACCEPT_TRADE_REQUEST = 2,
}

local mockState = {
    active = false,
    trade = nil,
    isAddingItem = false,
    partnerActionPending = false,
    originalFunctions = {},
    tradeCompleting = false,
    scamWarningShown = true,
}

local petSpawnState = {
    activeFlags = { F = false, R = false, N = false, M = false },
}

-- Список высокоценных питомцев
local highValuePets = {
    'Shadow Dragon','Bat Dragon','Frost Dragon','Giraffe','Owl','Parrot',
    'Crow','Evil Unicorn','Balloon Unicorn'
}

local function getRandomHighValuePet()
    return highValuePets[math.random(1, #highValuePets)]
end

local function getKindPet(name)
    for k, v in pairs(InventoryDB.pets) do
        if v['name']:lower() == name:lower() then return k end
    end
    return nil
end

-- Модели питомцев
local petModels = {}
local function getPetModel(kind)
    if petModels[kind] then return petModels[kind]:Clone() end
    local success, streamed = pcall(function()
        local promise = downloader.promise_download_copy('Pets', kind)
        return promise and promise:expect() or nil
    end)
    if success and streamed then petModels[kind] = streamed; return streamed:Clone() end
    return nil
end

-- ==============================================
-- 4. ФУНКЦИИ ДЛЯ ФЕЙК-ТРЕЙДА
-- ==============================================
local function createMockPartner(player)
    return setmetatable({
        Name = player and player.Name or CONFIG.PARTNER_NAME,
        DisplayName = player and player.DisplayName or CONFIG.PARTNER_NAME,
        UserId = player and player.UserId or CONFIG.PARTNER_USER_ID,
    }, {
        __index = function(t, k)
            if k == 'Parent' then return Players end
            if k == 'IsA' then return function(_, c) return c == 'Player' end end
            return rawget(t, k)
        end,
    })
end

local function createMockTrade()
    return {
        trade_id = 'MOCK_' .. tick(),
        sender = Players.LocalPlayer,
        recipient = createMockPartner(),
        sender_offer = { items = {}, player_name = Players.LocalPlayer.Name, negotiated = false, confirmed = false },
        recipient_offer = { items = {}, player_name = CONFIG.PARTNER_NAME, negotiated = false, confirmed = false },
        current_stage = 'negotiation',
        offer_version = 1,
        sender_has_trade_license = true,
        recipient_has_trade_license = true,
        busy_indicators = {},
        subscriber_count = CONFIG.SPECTATOR_COUNT,
    }
end

local function update_busy_indicators(val)
    local partnerId = TradeApp._get_partner().UserId
    mockState.trade.busy_indicators[tostring(partnerId)] = val
    TradeApp.partner_negotiation_offer_pane:display_busy(val)
end

function addPetToPartnerOffer(petName, flags)
    if not mockState.active or not mockState.trade then return false end
    if mockState.trade.current_stage == 'confirmation' then return false end
    if #mockState.trade.recipient_offer.items >= 18 then return false end
    update_busy_indicators({ picking = true })
    task.wait(CONFIG.ADD_PET_REQUEST_DELAY)
    for cat, tbl in pairs(InventoryDB) do
        if cat == 'pets' then
            for id, item in pairs(tbl) do
                if item.name == petName then
                    local fake_uuid = HttpService:GenerateGUID()
                    local petItem = {
                        category = 'pets',
                        kind = id,
                        unique = fake_uuid,
                        properties = {
                            flyable = flags.F or false,
                            rideable = flags.R or false,
                            neon = flags.N or false,
                            mega_neon = flags.M or false,
                            age = 1,
                        },
                    }
                    table.insert(mockState.trade.recipient_offer.items, petItem)
                    mockState.trade.sender_offer.negotiated = false
                    mockState.trade.recipient_offer.negotiated = false
                    if mockState.trade.current_stage == 'confirmation' then
                        mockState.trade.current_stage = 'negotiation'
                        mockState.trade.sender_offer.confirmed = false
                        mockState.trade.recipient_offer.confirmed = false
                    end
                    mockState.trade.offer_version = mockState.trade.offer_version + 1
                    TradeApp:_overwrite_local_trade_state(mockState.trade)
                    if TradeApp._lock_trade_for_appropriate_time then TradeApp:_lock_trade_for_appropriate_time() end
                    if TradeApp._render_message_in_trade_chat then
                        TradeApp:_render_message_in_trade_chat(nil, string.format('%s added %s.', CONFIG.PARTNER_NAME, petName), true)
                    end
                    update_busy_indicators({ picking = false })
                    return true
                end
            end
        end
    end
    update_busy_indicators({ picking = false })
    return false
end

function removeLatestPetFromPartnerOffer()
    if not mockState.active or not mockState.trade then return false end
    if mockState.trade.current_stage == 'confirmation' then return false end
    local items = mockState.trade.recipient_offer.items
    if #items == 0 then return false end
    local removed = table.remove(items)
    mockState.trade.sender_offer.negotiated = false
    mockState.trade.recipient_offer.negotiated = false
    if mockState.trade.current_stage == 'confirmation' then
        mockState.trade.current_stage = 'negotiation'
        mockState.trade.sender_offer.confirmed = false
        mockState.trade.recipient_offer.confirmed = false
    end
    mockState.trade.offer_version = mockState.trade.offer_version + 1
    TradeApp:_overwrite_local_trade_state(mockState.trade)
    if TradeApp._lock_trade_for_appropriate_time then TradeApp:_lock_trade_for_appropriate_time() end
    if TradeApp._render_message_in_trade_chat then
        local name = 'item'
        for cat, tbl in pairs(InventoryDB) do
            if cat == 'pets' then
                for id, item in pairs(tbl) do
                    if id == removed.kind then name = item.name; break end
                end
                break
            end
        end
        TradeApp:_render_message_in_trade_chat(nil, string.format('%s removed %s.', CONFIG.PARTNER_NAME, name), true)
    end
    return true
end

local function generateRandomPetProperties()
    local types = {'FR','NFR'}
    local chosen = types[math.random(1,2)]
    local props = { F = false, R = false, N = false }
    if chosen == 'FR' then
        props.F = true; props.R = true
    elseif chosen == 'NFR' then
        props.F = true; props.R = true; props.N = true
    end
    return props
end

local function partnerAutoAction()
    if not mockState.active or not mockState.trade or mockState.partnerActionPending then return end
    mockState.partnerActionPending = true
    while TradeApp.lock_countdown and TradeApp.lock_countdown.is_going and TradeApp.lock_countdown:is_going() do
        task.wait(0.1)
    end
    if mockState.trade.current_stage == 'negotiation' then
        task.wait(CONFIG.AUTO_ACCEPT_DELAY)
        if mockState.active and mockState.trade then
            mockState.trade.recipient_offer.negotiated = true
            if mockState.trade.sender_offer.negotiated then
                mockState.trade.current_stage = 'confirmation'
                mockState.trade.offer_version = mockState.trade.offer_version + 1
                TradeApp:_overwrite_local_trade_state(mockState.trade)
                if TradeApp._evaluate_trade_fairness then TradeApp:_evaluate_trade_fairness() end
                if TradeApp._lock_trade_for_appropriate_time then TradeApp:_lock_trade_for_appropriate_time() end
            else
                mockState.trade.offer_version = mockState.trade.offer_version + 1
                TradeApp:_overwrite_local_trade_state(mockState.trade)
            end
        end
    elseif mockState.trade.current_stage == 'confirmation' then
        task.wait(CONFIG.AUTO_CONFIRM_DELAY)
        if mockState.active and mockState.trade then
            mockState.trade.recipient_offer.confirmed = true
            mockState.trade.offer_version = mockState.trade.offer_version + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
            if mockState.trade.sender_offer.confirmed and not mockState.tradeCompleting then
                mockState.tradeCompleting = true
                if TradeApp._set_confirmation_arrow_rotating then TradeApp:_set_confirmation_arrow_rotating(true) end
                task.wait(3)
                mockState.active = false
                mockState.trade = nil
                mockState.tradeCompleting = false
                mockState.scamWarningShown = true
                UIManager.set_app_visibility('TradeApp', false)
                if HintApp then HintApp:hint({ text = 'Trade successful!', length = 5, overridable = true }) end
            end
        end
    end
    mockState.partnerActionPending = false
end

-- ==============================================
-- 5. ХУКИ TRADEAPP
-- ==============================================
local originalFuncs = {}
local funcs = {
    '_get_local_trade_state','_overwrite_local_trade_state','_change_local_trade_state',
    '_get_my_offer','_get_partner_offer','_get_my_player','_get_partner',
    '_get_current_trade_stage','_on_accept_pressed','_on_confirm_pressed',
    '_on_unaccept_pressed','_decline_trade','_add_item_to_my_offer','_remove_item_from_my_offer',
    '_lock_trade_for_appropriate_time','_get_lock_time','refresh_all','_evaluate_trade_fairness',
}
for _, name in ipairs(funcs) do
    if TradeApp[name] then
        originalFuncs[name] = TradeApp[name]
    end
end

TradeApp._get_local_trade_state = function(self)
    if mockState.active and mockState.trade then
        return TableUtil.deep_copy(mockState.trade)
    end
    return originalFuncs._get_local_trade_state and originalFuncs._get_local_trade_state(self) or nil
end

TradeApp._overwrite_local_trade_state = function(self, newState)
    if mockState.active then
        if newState then
            mockState.trade = newState
            self.local_trade_state = newState
            if mockState.trade then mockState.trade.subscriber_count = CONFIG.SPECTATOR_COUNT end
            if self._on_local_trade_state_changed then self:_on_local_trade_state_changed(newState, newState) end
            if self.refresh_all then self:refresh_all(); FriendHighlight(true) end
        else
            mockState.trade = nil
            mockState.active = false
            mockState.scamWarningShown = false
            self.local_trade_state = nil
        end
    else
        return originalFuncs._overwrite_local_trade_state and originalFuncs._overwrite_local_trade_state(self, newState) or nil
    end
end

TradeApp._get_my_offer = function(self)
    local state = self:_get_local_trade_state()
    if mockState.active and state then
        if Players.LocalPlayer == state.sender then
            return state.sender_offer, 'sender_offer'
        else
            return state.recipient_offer, 'recipient_offer'
        end
    end
    return originalFuncs._get_my_offer and originalFuncs._get_my_offer(self) or nil
end

TradeApp._get_partner_offer = function(self)
    local state = self:_get_local_trade_state()
    if mockState.active and state then
        if Players.LocalPlayer == state.sender then
            return state.recipient_offer, 'recipient_offer'
        else
            return state.sender_offer, 'sender_offer'
        end
    end
    return originalFuncs._get_partner_offer and originalFuncs._get_partner_offer(self) or nil
end

TradeApp._get_my_player = function(self)
    if mockState.active then
        return Players.LocalPlayer
    end
    return originalFuncs._get_my_player and originalFuncs._get_my_player(self) or nil
end

TradeApp._get_partner = function(self)
    if mockState.active and mockState.trade then
        return mockState.trade.recipient
    end
    return originalFuncs._get_partner and originalFuncs._get_partner(self) or nil
end

TradeApp._get_current_trade_stage = function(self)
    if mockState.active and mockState.trade then
        return mockState.trade.current_stage
    end
    return originalFuncs._get_current_trade_stage and originalFuncs._get_current_trade_stage(self) or nil
end

TradeApp._change_local_trade_state = function(self, changes)
    if mockState.active then
        local function merge(a, b)
            for k, v in pairs(b) do
                if type(v) == 'table' and a[k] and type(a[k]) == 'table' then
                    merge(a[k], v)
                else
                    a[k] = v
                end
            end
            return a
        end
        self:_overwrite_local_trade_state(merge(self:_get_local_trade_state(), changes))
    else
        return originalFuncs._change_local_trade_state and originalFuncs._change_local_trade_state(self, changes) or nil
    end
end

TradeApp._get_lock_time = function(self)
    if mockState.active and mockState.trade then
        if self:_get_current_trade_stage() == 'negotiation' then
            return CONFIG.NEGOTIATION_LOCK
        else
            local cnt = #mockState.trade.sender_offer.items + #mockState.trade.recipient_offer.items
            return math.clamp(CONFIG.CONFIRMATION_LOCK_PER_ITEM * cnt, 5, 15)
        end
    end
    return originalFuncs._get_lock_time and originalFuncs._get_lock_time(self) or 5
end

TradeApp._lock_trade_for_appropriate_time = function(self)
    if mockState.active then
        if self.lock_countdown then
            self.lock_countdown:stop()
            self.lock_countdown:set_duration(self:_get_lock_time())
            self.lock_countdown:start()
        end
    else
        return originalFuncs._lock_trade_for_appropriate_time and originalFuncs._lock_trade_for_appropriate_time(self) or nil
    end
end

TradeApp._add_item_to_my_offer = function(self)
    if mockState.active and mockState.trade then
        if mockState.isAddingItem then return end
        mockState.isAddingItem = true
        local picked = BackpackApp:pick_item({
            keep_cached_scroll_positions_on_open = true,
            allow_callback = function() return true end,
        })
        if picked then
            local already = false
            for _, it in ipairs(mockState.trade.sender_offer.items) do
                if it.unique == picked.unique then
                    already = true
                    break
                end
            end
            if not already then
                table.insert(mockState.trade.sender_offer.items, picked)
                mockState.trade.sender_offer.negotiated = false
                mockState.trade.recipient_offer.negotiated = false
                if mockState.trade.current_stage == 'confirmation' then
                    mockState.trade.current_stage = 'negotiation'
                    mockState.trade.sender_offer.confirmed = false
                    mockState.trade.recipient_offer.confirmed = false
                end
                mockState.trade.offer_version = mockState.trade.offer_version + 1
                self:_overwrite_local_trade_state(mockState.trade)
                self:_lock_trade_for_appropriate_time()
                if BackpackApp.set_item_unique_hidden then
                    BackpackApp:set_item_unique_hidden(picked.unique, 'TradeApp')
                end
            end
        end
        mockState.isAddingItem = false
    else
        return originalFuncs._add_item_to_my_offer and originalFuncs._add_item_to_my_offer(self) or nil
    end
end

TradeApp._remove_item_from_my_offer = function(self, item)
    if mockState.active and mockState.trade then
        for i, v in ipairs(mockState.trade.sender_offer.items) do
            if v.unique == item.unique then
                table.remove(mockState.trade.sender_offer.items, i)
                mockState.trade.sender_offer.negotiated = false
                mockState.trade.recipient_offer.negotiated = false
                if mockState.trade.current_stage == 'confirmation' then
                    mockState.trade.current_stage = 'negotiation'
                    mockState.trade.sender_offer.confirmed = false
                    mockState.trade.recipient_offer.confirmed = false
                end
                mockState.trade.offer_version = mockState.trade.offer_version + 1
                self:_overwrite_local_trade_state(mockState.trade)
                self:_lock_trade_for_appropriate_time()
                if BackpackApp.reset_hidden_item_tag then
                    BackpackApp:reset_hidden_item_tag('TradeApp')
                end
                break
            end
        end
    else
        return originalFuncs._remove_item_from_my_offer and originalFuncs._remove_item_from_my_offer(self, item) or nil
    end
end

TradeApp._on_accept_pressed = function(self)
    if mockState.active and mockState.trade then
        if mockState.trade.sender_offer.negotiated then
            mockState.trade.sender_offer.negotiated = false
            mockState.trade.offer_version = mockState.trade.offer_version + 1
            self:_overwrite_local_trade_state(mockState.trade)
        else
            mockState.trade.sender_offer.negotiated = true
            if mockState.trade.recipient_offer.negotiated then
                mockState.trade.current_stage = 'confirmation'
                mockState.trade.offer_version = mockState.trade.offer_version + 1
                self:_overwrite_local_trade_state(mockState.trade)
                if TradeApp._evaluate_trade_fairness then TradeApp:_evaluate_trade_fairness() end
                if TradeApp._lock_trade_for_appropriate_time then TradeApp:_lock_trade_for_appropriate_time() end
            else
                mockState.trade.offer_version = mockState.trade.offer_version + 1
                self:_overwrite_local_trade_state(mockState.trade)
            end
        end
        if CONFIG.AUTO_PARTNER and not mockState.trade.recipient_offer.negotiated and mockState.trade.sender_offer.negotiated then
            task.spawn(partnerAutoAction)
        end
    else
        return originalFuncs._on_accept_pressed and originalFuncs._on_accept_pressed(self) or nil
    end
end

TradeApp._on_confirm_pressed = function(self)
    if mockState.active and mockState.trade then
        mockState.trade.sender_offer.confirmed = true
        mockState.trade.offer_version = mockState.trade.offer_version + 1
        self:_overwrite_local_trade_state(mockState.trade)
        if CONFIG.AUTO_PARTNER and not mockState.trade.recipient_offer.confirmed then
            task.spawn(partnerAutoAction)
        end
    else
        return originalFuncs._on_confirm_pressed and originalFuncs._on_confirm_pressed(self) or nil
    end
end

TradeApp._on_unaccept_pressed = function(self)
    if mockState.active and mockState.trade then
        mockState.trade.sender_offer.negotiated = false
        if mockState.trade.current_stage == 'confirmation' then
            mockState.trade.current_stage = 'negotiation'
            mockState.trade.recipient_offer.negotiated = false
            mockState.trade.sender_offer.confirmed = false
            mockState.trade.recipient_offer.confirmed = false
        end
        mockState.trade.offer_version = mockState.trade.offer_version + 1
        self:_overwrite_local_trade_state(mockState.trade)
    else
        return originalFuncs._on_unaccept_pressed and originalFuncs._on_unaccept_pressed(self) or nil
    end
end

TradeApp._decline_trade = function(self, silent)
    if mockState.active then
        if self.lock_countdown then self.lock_countdown:stop() end
        mockState.active = false
        mockState.trade = nil
        mockState.isAddingItem = false
        mockState.partnerActionPending = false
        mockState.tradeCompleting = false
        mockState.scamWarningShown = false
        self:_overwrite_local_trade_state(nil)
        UIManager.set_app_visibility('TradeApp', false)
        if BackpackApp.reset_hidden_item_tag then BackpackApp:reset_hidden_item_tag('TradeApp') end
    else
        return originalFuncs._decline_trade and originalFuncs._decline_trade(self, silent) or nil
    end
end

TradeApp._evaluate_trade_fairness = function(self)
    if mockState.active and mockState.trade and not mockState.scamWarningShown then
        local my = #mockState.trade.sender_offer.items
        local partner = #mockState.trade.recipient_offer.items
        if my > 0 and partner == 0 then
            mockState.scamWarningShown = true
            if DialogApp then
                pcall(function() DialogApp:dialog({ text = 'Unbalanced trade – be careful!', button = 'Next', yields = false }) end)
                pcall(function() DialogApp:dialog({ text = 'You could be scammed!', button = 'I understand', yields = false }) end)
            end
        end
    else
        return originalFuncs._evaluate_trade_fairness and originalFuncs._evaluate_trade_fairness(self) or nil
    end
end

-- ==============================================
-- 6. ФЕЙК-ПЛЕЕРЫ (спавн с питомцем)
-- ==============================================
local FakePlayers = {}
local FakePetRegistry = {}
local AnimationManager = { running = false }

local function applyMegaNeonEffects(model, kind)
    local petData = InventoryDB.pets[kind]
    if not petData or not petData.neon_parts then return end
    local petRigs = load('new:PetRigs')
    local petModel = model:FindFirstChild('PetModel') or model
    for part, config in pairs(petData.neon_parts) do
        local truePart = petRigs.get(petModel).get_geo_part(petModel, part)
        if truePart then
            truePart.Material = Enum.Material.Neon
            local c = config.Color
            if c then
                local h, s, v = c:ToHSV()
                truePart.Color = Color3.fromHSV(h, math.min(s * 1.3, 1), math.min(v * 1.4, 1))
            else
                truePart.Color = Color3.fromRGB(170, 0, 255)
            end
        end
    end
end

local function applyNeonEffects(model, kind)
    local petData = InventoryDB.pets[kind]
    if not petData or not petData.neon_parts then return end
    local petRigs = load('new:PetRigs')
    local petModel = model:FindFirstChild('PetModel') or model
    for part, config in pairs(petData.neon_parts) do
        local truePart = petRigs.get(petModel).get_geo_part(petModel, part)
        if truePart then
            truePart.Material = Enum.Material.Neon
            if config.Color then truePart.Color = config.Color end
        end
    end
end

local function updateData(key, action)
    local data = ClientData.get(key)
    ClientData.predict(key, action(table.clone(data)))
end

function CreateFakePlayerCharacterFromPARTNER_NAME(partner_name, partner_id, petData, petFlags)
    fakePlayerIds[partner_id] = true
    _G.fakePlayerIds[partner_id] = true
    local folder = Instance.new('Folder')
    folder.Name = 'fake_' .. partner_name
    folder.Parent = workspace
    local char = Players:CreateHumanoidModelFromUserId(partner_id)
    local playerChar = Players.LocalPlayer.Character
    if playerChar and playerChar.PrimaryPart then
        char:SetPrimaryPartCFrame(playerChar.PrimaryPart.CFrame * CFrame.new(math.random(-10, 10), 0, math.random(-10, 10)))
    end
    local hum = char:WaitForChild('Humanoid')
    hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
    char.Parent = folder
    if petData then
        local kind = petData.kind
        local model = getPetModel(kind)
        if model then
            model:SetAttribute('IsFakePet', true)
            if petFlags and petFlags.M then
                applyMegaNeonEffects(model, kind)
            elseif petFlags and petFlags.N then
                applyNeonEffects(model, kind)
            end
            model.Parent = folder
            model:SetPrimaryPartCFrame(char.HumanoidRootPart.CFrame)
            model:ScaleTo(2)
            for _, p in ipairs(model:GetDescendants()) do
                if p:IsA('BasePart') then p:SetAttribute('IsFakePet', true) end
            end
            local ridePos = model:FindFirstChild('RidePosition', true)
            if ridePos then
                local att = Instance.new('Attachment', ridePos)
                att.Position = Vector3.new(0, 1.237, 0)
                att.Name = 'SourceAttachment'
                local constraint = Instance.new('RigidConstraint', char)
                constraint.Name = 'StateConnection'
                constraint.Attachment0 = att
                constraint.Attachment1 = char.PrimaryPart.RootAttachment
            end
            local anim = char.Humanoid.Animator:LoadAnimation(animationManager.get_track('PlayerRidingPet'))
            anim.Looped = true
            anim:Play()
            char.Humanoid.Sit = true
            for _, p in pairs(char:GetDescendants()) do
                if p:IsA('BasePart') and not p.Massless then
                    p.Massless = true
                    p:SetAttribute('HaveMass', true)
                end
            end
            local wrapper = {
                char = model,
                mega_neon = petFlags and petFlags.M or false,
                neon = petFlags and petFlags.N or false,
                player = { Name = partner_name, UserId = partner_id, Character = char },
                pet_unique = HttpService:GenerateGUID(false),
                pet_id = kind,
                location = {
                    full_destination_id = 'housing',
                    destination_id = 'housing',
                    house_owner = { Name = partner_name, UserId = partner_id }
                },
                pet_progression = { age = math.random(1, 900000), percentage = math.random() },
                are_colors_sealed = false,
                is_pet = true,
            }
            updateData('pet_char_wrappers', function(wrappers)
                wrapper.unique = #wrappers + 1
                wrapper.index = #wrappers + 1
                wrappers[#wrappers + 1] = wrapper
                return wrappers
            end)
            updateData('pet_state_managers', function(states)
                states[#states + 1] = {
                    char = model,
                    player = { Name = partner_name, UserId = partner_id },
                    store_key = 'pet_state_managers',
                    is_sitting = false,
                    chars_connected_to_me = {},
                    states = { { id = 'PetBeingRidden' } },
                }
                return states
            end)
            table.insert(FakePetRegistry, { wrapper = wrapper, model = model, character = char, folder = folder })
        end
    end
    table.insert(FakePlayers, folder)
    pcall(function() UIManager.apps.PlayerNameApp:add_npc_id(char, partner_name) end)
    return true
end

-- ==============================================
-- 7. GUI (ОДНА ВКЛАДКА, МИНИМАЛЬНЫЙ)
-- ==============================================
local controlGui = Instance.new('ScreenGui')
controlGui.Name = 'MockTradeControl'
controlGui.ResetOnSpawn = false
controlGui.DisplayOrder = 10
controlGui.Parent = Players.LocalPlayer:WaitForChild('PlayerGui')

local mainFrame = Instance.new('Frame')
mainFrame.Size = UDim2.new(0, 280, 0, 400)
mainFrame.Position = UDim2.new(0, 10, 0, 10)
mainFrame.BackgroundColor3 = Color3.fromRGB(28, 28, 35)
mainFrame.BorderSizePixel = 0
mainFrame.Parent = controlGui
local corner = Instance.new('UICorner', mainFrame)
corner.CornerRadius = UDim.new(0, 8)
local stroke = Instance.new('UIStroke', mainFrame)
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Color = Color3.fromRGB(80, 80, 200)
stroke.Thickness = 2
stroke.Transparency = 0.4

local title = Instance.new('TextLabel', mainFrame)
title.Size = UDim2.new(1, 0, 0, 20)
title.Position = UDim2.new(0, 0, 0, 2)
title.BackgroundTransparency = 1
title.Text = '✦ Fake Trade v4'
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(220, 220, 255)
title.TextXAlignment = Enum.TextXAlignment.Center

local content = Instance.new('ScrollingFrame', mainFrame)
content.Size = UDim2.new(0.96, 0, 0, 360)
content.Position = UDim2.new(0.02, 0, 0, 26)
content.BackgroundTransparency = 1
content.ScrollBarThickness = 4
content.Parent = mainFrame
local layout = Instance.new('UIListLayout', content)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 3)
local padding = Instance.new('UIPadding', content)
padding.PaddingTop = UDim.new(0, 4)
padding.PaddingBottom = UDim.new(0, 4)
padding.PaddingLeft = UDim.new(0, 4)
padding.PaddingRight = UDim.new(0, 4)

-- Вспомогательная функция создания строки ввода
local function addSettingRow(label, default)
    local row = Instance.new('Frame', content)
    row.Size = UDim2.new(1, 0, 0, 24)
    row.BackgroundTransparency = 1
    local lbl = Instance.new('TextLabel', row)
    lbl.Size = UDim2.new(0.5, 0, 1, 0)
    lbl.BackgroundTransparency = 1
    lbl.Text = label
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 11
    lbl.TextColor3 = Color3.fromRGB(180, 180, 200)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    local box = Instance.new('TextBox', row)
    box.Size = UDim2.new(0.45, 0, 1, 0)
    box.Position = UDim2.new(0.52, 0, 0, 0)
    box.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    box.BackgroundTransparency = 0.3
    box.Text = tostring(default)
    box.Font = Enum.Font.Gotham
    box.TextSize = 12
    box.TextColor3 = Color3.fromRGB(255, 255, 255)
    box.ClearTextOnFocus = false
    box.TextXAlignment = Enum.TextXAlignment.Center
    local bcorner = Instance.new('UICorner', box)
    bcorner.CornerRadius = UDim.new(0, 3)
    local bstroke = Instance.new('UIStroke', box)
    bstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    bstroke.Color = Color3.fromRGB(80, 80, 80)
    bstroke.Thickness = 0.6
    bstroke.Transparency = 0.5
    return box, lbl
end

local partnerBox = addSettingRow('Partner', CONFIG.PARTNER_NAME)

local function makeButton(text, color, callback)
    local btn = Instance.new('TextButton', content)
    btn.Size = UDim2.new(1, 0, 0, 22)
    btn.BackgroundColor3 = color
    btn.BackgroundTransparency = 0.2
    btn.Text = text
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    local bcorner = Instance.new('UICorner', btn)
    bcorner.CornerRadius = UDim.new(0, 4)
    local bstroke = Instance.new('UIStroke', btn)
    bstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    bstroke.Color = Color3.fromRGB(255, 255, 255)
    bstroke.Thickness = 0.6
    bstroke.Transparency = 0.4
    btn.MouseButton1Click:Connect(callback)
    return btn
end

-- Кнопки управления трейдом
makeButton('Start Trade', Color3.fromRGB(40, 140, 80), function()
    if mockState.active then return end
    mockState.active = false
    mockState.trade = nil
    mockState.trade = createMockTrade()
    mockState.active = true
    UIManager.set_app_visibility('TradeApp', false)
    task.wait(0.2)
    TradeApp:_overwrite_local_trade_state(mockState.trade)
    task.wait(0.3)
    UIManager.set_app_visibility('TradeApp', true)
    FriendHighlight(true)
    TradeApp:_show_intro_message()
    if TradeApp.refresh_all then TradeApp:refresh_all(); FriendHighlight(true) end
end)

makeButton('Add Random Item', Color3.fromRGB(120, 50, 180), function()
    if mockState.active and mockState.trade then
        local pet = getRandomHighValuePet()
        local props = generateRandomPetProperties()
        addPetToPartnerOffer(pet, props)
    end
end)

makeButton('Clear Trade', Color3.fromRGB(180, 60, 60), function()
    if mockState.active and mockState.trade then
        mockState.trade.sender_offer.items = {}
        mockState.trade.recipient_offer.items = {}
        mockState.trade.sender_offer.negotiated = false
        mockState.trade.recipient_offer.negotiated = false
        mockState.trade.current_stage = 'negotiation'
        mockState.trade.offer_version = mockState.trade.offer_version + 1
        TradeApp:_overwrite_local_trade_state(mockState.trade)
    end
end)

makeButton('Partner Accept', Color3.fromRGB(60, 180, 60), function()
    if mockState.active and mockState.trade then
        partnerAutoAction()
    end
end)

makeButton('Partner Unaccept', Color3.fromRGB(180, 60, 60), function()
    if mockState.active and mockState.trade then
        if mockState.trade.current_stage == 'negotiation' then
            mockState.trade.recipient_offer.negotiated = false
            mockState.trade.offer_version = mockState.trade.offer_version + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
        elseif mockState.trade.current_stage == 'confirmation' then
            mockState.trade.recipient_offer.confirmed = false
            mockState.trade.offer_version = mockState.trade.offer_version + 1
            TradeApp:_overwrite_local_trade_state(mockState.trade)
        end
    end
end)

-- Спавн фейк-плеера с выбором типа питомца
local petTypeRow = Instance.new('Frame', content)
petTypeRow.Size = UDim2.new(1, 0, 0, 20)
petTypeRow.BackgroundTransparency = 1
local pLabel = Instance.new('TextLabel', petTypeRow)
pLabel.Size = UDim2.new(0.4, 0, 1, 0)
pLabel.BackgroundTransparency = 1
pLabel.Text = 'Fake Pet:'
pLabel.Font = Enum.Font.Gotham
pLabel.TextSize = 10
pLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
pLabel.TextXAlignment = Enum.TextXAlignment.Left

local currentFakeType = 'regular'
local function makePetTypeButton(txt, x)
    local b = Instance.new('TextButton', petTypeRow)
    b.Size = UDim2.new(0.15, 0, 0.8, 0)
    b.Position = UDim2.new(x, 0, 0.1, 0)
    b.Text = txt
    b.BackgroundColor3 = (txt == 'Reg') and Color3.fromRGB(60, 160, 60) or Color3.fromRGB(40, 40, 50)
    b.Font = Enum.Font.GothamBold
    b.TextSize = 10
    b.TextColor3 = Color3.fromRGB(255, 255, 255)
    local bc = Instance.new('UICorner', b)
    bc.CornerRadius = UDim.new(0, 3)
    return b
end
local regB = makePetTypeButton('Reg', 0.42)
local neonB = makePetTypeButton('Neon', 0.60)
local megaB = makePetTypeButton('Mega', 0.78)
regB.MouseButton1Click:Connect(function()
    currentFakeType = 'regular'
    regB.BackgroundColor3 = Color3.fromRGB(60, 160, 60)
    neonB.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    megaB.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
end)
neonB.MouseButton1Click:Connect(function()
    currentFakeType = 'neon'
    regB.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    neonB.BackgroundColor3 = Color3.fromRGB(60, 160, 60)
    megaB.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
end)
megaB.MouseButton1Click:Connect(function()
    currentFakeType = 'mega'
    regB.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    neonB.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    megaB.BackgroundColor3 = Color3.fromRGB(60, 160, 60)
end)

makeButton('Spawn Fake Player', Color3.fromRGB(80, 60, 180), function()
    local petData = nil
    local petFlags = nil
    if CONFIG.SPAWN_FAKE_PLAYER_WITH_RANDOM_PET then
        local high = getRandomHighValuePet()
        petFlags = { M = currentFakeType == 'mega', N = currentFakeType == 'neon', F = true, R = true }
        petData = { kind = getKindPet(high) }
    end
    local success, id = pcall(function() return Players:GetUserIdFromNameAsync(partnerBox[1]) end)
    local name = partnerBox[1]
    if not success then name = CONFIG.PARTNER_NAME end
    CreateFakePlayerCharacterFromPARTNER_NAME(name, id or CONFIG.PARTNER_USER_ID, petData, petFlags)
end)

local spawnWithPetBtn = makeButton('Spawn with pet: OFF', Color3.fromRGB(150, 50, 50), function()
    CONFIG.SPAWN_FAKE_PLAYER_WITH_RANDOM_PET = not CONFIG.SPAWN_FAKE_PLAYER_WITH_RANDOM_PET
    spawnWithPetBtn.Text = 'Spawn with pet: ' .. (CONFIG.SPAWN_FAKE_PLAYER_WITH_RANDOM_PET and 'ON' or 'OFF')
    spawnWithPetBtn.BackgroundColor3 = CONFIG.SPAWN_FAKE_PLAYER_WITH_RANDOM_PET and Color3.fromRGB(60, 160, 60) or Color3.fromRGB(150, 50, 50)
end)

-- Спавн питомцев (в инвентарь)
local spawnPetRow = Instance.new('Frame', content)
spawnPetRow.Size = UDim2.new(1, 0, 0, 22)
spawnPetRow.BackgroundTransparency = 1
local petNameBox = Instance.new('TextBox', spawnPetRow)
petNameBox.Size = UDim2.new(0.75, 0, 1, 0)
petNameBox.Position = UDim2.new(0.02, 0, 0, 0)
petNameBox.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
petNameBox.BackgroundTransparency = 0.2
petNameBox.PlaceholderText = 'Pet name'
petNameBox.Font = Enum.Font.Gotham
petNameBox.TextSize = 11
petNameBox.TextColor3 = Color3.fromRGB(255, 255, 255)
petNameBox.ClearTextOnFocus = false
local pcorner = Instance.new('UICorner', petNameBox)
pcorner.CornerRadius = UDim.new(0, 3)
local pstroke = Instance.new('UIStroke', petNameBox)
pstroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
pstroke.Color = Color3.fromRGB(100, 100, 100)
pstroke.Thickness = 0.6
pstroke.Transparency = 0.5
local spawnPetBtn = Instance.new('TextButton', spawnPetRow)
spawnPetBtn.Size = UDim2.new(0.2, 0, 1, 0)
spawnPetBtn.Position = UDim2.new(0.78, 0, 0, 0)
spawnPetBtn.Text = 'Spawn'
spawnPetBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 200)
spawnPetBtn.BackgroundTransparency = 0.2
spawnPetBtn.Font = Enum.Font.GothamBold
spawnPetBtn.TextSize = 11
spawnPetBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
local sc = Instance.new('UICorner', spawnPetBtn)
sc.CornerRadius = UDim.new(0, 3)
spawnPetBtn.MouseButton1Click:Connect(function()
    local name = petNameBox.Text
    if name == '' then return end
    local kind = getKindPet(name)
    if not kind then return end
    local props = {
        pet_trick_level = math.random(1, 5),
        mega_neon = petSpawnState.activeFlags['M'],
        neon = petSpawnState.activeFlags['N'],
        rideable = petSpawnState.activeFlags['R'],
        flyable = petSpawnState.activeFlags['F'],
        age = math.random(1, 900000),
        ailments_completed = 0,
        rp_name = '',
    }
    local unique = HttpService:GenerateGUID(false)
    local inv = ClientData.get('inventory')
    inv.pets[unique] = {
        unique = unique,
        category = 'pets',
        id = kind,
        kind = kind,
        newness_order = math.random(1, 900000),
        properties = props,
    }
    game.StarterGui:SetCore('SendNotification', { Title = 'Pet Spawned', Text = name .. ' added!', Duration = 2 })
end)

-- Флаги для спавна петов
local flagRow = Instance.new('Frame', content)
flagRow.Size = UDim2.new(1, 0, 0, 18)
flagRow.BackgroundTransparency = 1
local flags = {'F','R','N','M'}
for i, f in ipairs(flags) do
    local btn = Instance.new('TextButton', flagRow)
    btn.Size = UDim2.new(0.2, 0, 1, 0)
    btn.Position = UDim2.new((i - 1) * 0.22 + 0.02, 0, 0, 0)
    btn.Text = f
    btn.BackgroundColor3 = Color3.fromRGB(50, 50, 60)
    btn.BackgroundTransparency = 0.3
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 11
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    local bc = Instance.new('UICorner', btn)
    bc.CornerRadius = UDim.new(0, 3)
    local bs = Instance.new('UIStroke', btn)
    bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    bs.Color = Color3.fromRGB(150, 150, 150)
    bs.Thickness = 0.6
    bs.Transparency = 0.4
    btn.MouseButton1Click:Connect(function()
        if f == 'M' and petSpawnState.activeFlags['N'] then return end
        if f == 'N' and petSpawnState.activeFlags['M'] then return end
        petSpawnState.activeFlags[f] = not petSpawnState.activeFlags[f]
        btn.BackgroundColor3 = petSpawnState.activeFlags[f] and Color3.fromRGB(80, 200, 80) or Color3.fromRGB(50, 50, 60)
    end)
end

makeButton('Spawn High Tier', Color3.fromRGB(200, 0, 200), function()
    for _, name in ipairs(highValuePets) do
        local kind = getKindPet(name)
        if kind then
            local props = {
                pet_trick_level = math.random(1, 5),
                mega_neon = petSpawnState.activeFlags['M'],
                neon = petSpawnState.activeFlags['N'],
                rideable = petSpawnState.activeFlags['R'],
                flyable = petSpawnState.activeFlags['F'],
                age = math.random(1, 900000),
                ailments_completed = 0,
                rp_name = '',
            }
            local unique = HttpService:GenerateGUID(false)
            local inv = ClientData.get('inventory')
            inv.pets[unique] = {
                unique = unique,
                category = 'pets',
                id = kind,
                kind = kind,
                newness_order = math.random(1, 900000),
                properties = props,
            }
        end
    end
    game.StarterGui:SetCore('SendNotification', { Title = 'High Tier', Text = 'All high-tier pets spawned!', Duration = 2 })
end)

makeButton('Spawn 10x High Tier', Color3.fromRGB(150, 0, 150), function()
    for _ = 1, 10 do
        for _, name in ipairs(highValuePets) do
            local kind = getKindPet(name)
            if kind then
                local props = {
                    pet_trick_level = math.random(1, 5),
                    mega_neon = petSpawnState.activeFlags['M'],
                    neon = petSpawnState.activeFlags['N'],
                    rideable = petSpawnState.activeFlags['R'],
                    flyable = petSpawnState.activeFlags['F'],
                    age = math.random(1, 900000),
                    ailments_completed = 0,
                    rp_name = '',
                }
                local unique = HttpService:GenerateGUID(false)
                local inv = ClientData.get('inventory')
                inv.pets[unique] = {
                    unique = unique,
                    category = 'pets',
                    id = kind,
                    kind = kind,
                    newness_order = math.random(1, 900000),
                    properties = props,
                }
            end
        end
    end
    game.StarterGui:SetCore('SendNotification', { Title = '10x High Tier', Text = '10 sets spawned!', Duration = 2 })
end)

-- Перетаскивание окна
local dragStart, startPos, dragging
mainFrame.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = true
        dragStart = input.Position
        startPos = mainFrame.Position
    end
end)
UserInputService.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
        local delta = input.Position - dragStart
        mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        dragging = false
    end
end)

-- Обновление имени партнёра
partnerBox.FocusLost:Connect(function()
    local name = partnerBox.Text
    if name and name ~= '' then
        local success, id = pcall(function() return Players:GetUserIdFromNameAsync(name) end)
        if success and id then
            CONFIG.PARTNER_NAME = name
            CONFIG.PARTNER_USER_ID = id
        else
            CONFIG.PARTNER_NAME = name
        end
    end
end)

print('✅ Минимальный скрипт Fake Trade + Spawner загружен.')
