local db = require 'server.player.db'

---@type table<number, OxPlayer>
local PlayerRegistry = {}

---@type table<number, number>
local playerIdFromUserId = {}

---@type table<number, true>
local connectingPlayers = {}

local OxPlayer = require 'server.player.class'

local function addPlayer(playerId, username)
    local primaryIdentifier = Shared.SV_LAN and 'fayoum' or GetPlayerIdentifierByType(playerId, Server.PRIMARY_IDENTIFIER)

    if not primaryIdentifier then
        return nil, ("unable to determine '%s' identifier."):format(Server.PRIMARY_IDENTIFIER)
    end

    primaryIdentifier = primaryIdentifier:gsub('([^:]+):', '')
    local userId = db.getUserFromIdentifier(primaryIdentifier, false)

    if Ox.GetPlayerFromUserId(userId) then
        if not Shared.DEBUG then
            return nil, ("userId '%d' is already active."):format(userId)
        end

        local newestUserid = db.getUserFromIdentifier(primaryIdentifier, true)

        if newestUserid ~= userId then
            --[[ We found another user, let's use that instead! ]]
            userId = newestUserid
        else
            --[[ We don't have another user to use, let's force the creation of a new one! ]]
            userId = nil
        end
    end

    if not userId then
        username = utf8.len(username), string.len(username)
        userId = db.createUser(username, Ox.GetIdentifiers(playerId)) --[[@as number]]
    end

    local player = OxPlayer.new({
        source = playerId,
        userid = userId,
        username = username,
        private = {
            inScope = {},
            groups = {},
            statuses = {},
            licenses = {},
            metadata = {},
        }
    })

    PlayerRegistry[playerId] = player
    playerIdFromUserId[userId] = playerId

    return player
end

local function removePlayer(playerId, userId, reason)
    PlayerRegistry[playerId] = nil
    playerIdFromUserId[userId] = nil

    for _, player in pairs(PlayerRegistry) do
        player.private.inScope[playerId] = nil
    end

    --[[ TODO: Log session ended ]]
end

local function assignNonTemporaryId(tempId, newId)
    local player = PlayerRegistry[tempId]

    if not player then return end

    PlayerRegistry[tempId] = nil
    PlayerRegistry[newId] = player
    playerIdFromUserId[player.userid] = newId

    player:setAsJoined(newId)
end

---Returns an instance of OxPlayer belonging to the given playerId.
---@param playerId number
---@return OxPlayer
function Ox.GetPlayer(playerId)
    return PlayerRegistry[playerId]
end

function Ox.GetPlayerFromUserId(userId)
    local playerId = playerIdFromUserId[userId]

    return playerId and PlayerRegistry[playerId] or nil
end

function Ox.GetAllPlayers()
    return PlayerRegistry
end
---Check if a player matches filter parameters.
---@param player OxPlayer
---@param filter table
---@return boolean?
local function filterPlayer(player, filter)
    local metadata = player.private.metadata

    for k, v in pairs(filter) do
        if k == 'groups' then
            if not player:hasGroup(v) then
                return
            end
        elseif player[k] ~= v and metadata[k] ~= v then
            return
        end
    end

    return true
end

---Returns the first player that matches the filter properties.
---@param filter table
---@return OxPlayer?
function Ox.GetPlayerByFilter(filter)
    for _, player in pairs(PlayerRegistry) do
        if player.charid then
            if filterPlayer(player, filter) then
                return player
            end
        end
    end
end

---Returns an array of all players matching the filter properties.
---@param filter table?
---@return OxPlayer[]
function Ox.GetPlayers(filter)
    local size = 0
    local players = {}

    for _, player in pairs(PlayerRegistry) do
        if player.charid then
            if not filter or filterPlayer(player, filter) then
                size += 1
                players[size] = player
            end
        end
    end

    return players
end

local serverLockdown

RegisterNetEvent('ox:playerJoined', function()
    local playerId = source

    if serverLockdown then
        return DropPlayer(playerId, serverLockdown)
    end

    ---@type OxPlayer?
    local player = PlayerRegistry[playerId]

    if not player then
        player, err = addPlayer(playerId, GetPlayerName(playerId))

        if player then
            player:setAsJoined(playerId)
        end
    end

    if err or not player then
        return DropPlayer(playerId, err or 'could not load player')
    end

    player.characters = player:selectCharacters()

    TriggerClientEvent('ox:selectCharacter', playerId, player.characters)
end)

AddEventHandler('playerJoining', function(tempId)
    local playerId = source
    tempId = tonumber(tempId) --[[@as number why the hell is this a string]]
    connectingPlayers[tempId] = nil

    assignNonTemporaryId(tempId, playerId)
end)

AddEventHandler('playerConnecting', function(username, _, deferrals)
    local tempId = source
    deferrals.defer()

    if serverLockdown then
        return deferrals.done(serverLockdown)
    end

    local _, err = addPlayer(tempId, username)

    if err then
        return deferrals.done(err)
    end

    connectingPlayers[tempId] = true

    deferrals.done()
end)

CreateThread(function()
    local GetPlayerEndpoint = GetPlayerEndpoint

    while true do
        Wait(30000)

        -- If a player quits during the connection phase (and before joining)
        -- the tempId may stay active for several minutes.
        for tempId in pairs(connectingPlayers) do
            ---@diagnostic disable-next-line: param-type-mismatch
            if not GetPlayerEndpoint(tempId) then
                local player = PlayerRegistry[tempId]
                connectingPlayers[tempId] = nil
                PlayerRegistry[tempId] = nil
                playerIdFromUserId[player.userid] = nil
            end
        end
    end
end)

AddEventHandler('txAdmin:events:serverShuttingDown', function()
    serverLockdown = 'The server is about to restart. You cannot join at this time.'

    Ox.SaveAllPlayers()

    for playerId, player in pairs(PlayerRegistry) do
        player.charid = nil
        DropPlayer(tostring(playerId), 'Server is restarting.')
    end
end)

AddEventHandler('playerDropped', function(reason)
    local playerId = source
    local player = PlayerRegistry[playerId]

    if player then
        player:logout(true)

        removePlayer(player.source, player.userid, ('Dropped, %s'):format(reason) )
    end
end)

return PlayerRegistry
