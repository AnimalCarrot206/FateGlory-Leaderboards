local Players = game:GetService("Players")
local MemoryStoreService = game:GetService("MemoryStoreService")

local WEEKLY_PREFIX = "WEEKLY"
local MONTHLY_PREFIX = "MONTHLY"

local SECONDS_IN_WEEK = 7 * 24 * 3600
local SECONDS_IN_MONTHS = 30 * 24 * 3600

local RETRY_WAIT_TIME = 1

local LeaderboardsResetTimeMemoryStore = 
	MemoryStoreService:GetSortedMap("LeaderboardsResetTimeMemoryStore")

-- Useful function to retry network reqeusts
local function pcallUntilSucceed(func, ...)
	local result = table.pack(pcall(func, ...))
	local isSuccess = result[1]

	while not isSuccess do
		task.wait(RETRY_WAIT_TIME)
		result = table.pack(pcall(func, ...))
		isSuccess = result[1]
	end

	return table.unpack(result)
end

-- Making a "class" for each leadeboard
-- Useful for separating them
local LeaderboardSortedMap = {} 
do
	LeaderboardSortedMap.__index = LeaderboardSortedMap
	
	-- Default constructor
	function LeaderboardSortedMap.new(name: string, defaultValue: number, refreshTimeInSec: number)
		local newLeaderboard = {}
		newLeaderboard._memoryStore = MemoryStoreService:GetSortedMap(name)
		newLeaderboard._refreshTime = refreshTimeInSec
		newLeaderboard._lastRefreshTime = 0
		newLeaderboard._defaultValue = defaultValue
		newLeaderboard._name = name

		return setmetatable(newLeaderboard, LeaderboardSortedMap)
	end
	
	-- Retrieves top |n| (depends on playersCount argument) players from MemoryStore
	function LeaderboardSortedMap:getTop(playersCount: number): {{userId: number, value: number}}
		local memoryStoreSortedMap = self._memoryStore :: MemoryStoreSortedMap

		local _, top = pcallUntilSucceed(
			memoryStoreSortedMap.GetRangeAsync,
			memoryStoreSortedMap,
			Enum.SortDirection.Descending,
			playersCount
		)
		
		local result = {}
		for place, item: {key: number, value: number} in ipairs(top) do
			result[place] = {
				userId = item.key,
				value = item.value,
			}
		end

		return result
	end
	
	-- Useful for getting a specific player's record
	function LeaderboardSortedMap:getPlayerValue(userId: number): number?
		local memoryStoreSortedMap = self._memoryStore :: MemoryStoreSortedMap

		local _, item, _ = pcallUntilSucceed(
			memoryStoreSortedMap.GetAsync,
			memoryStoreSortedMap,
			tostring(userId)
		)
		return item or self._defaultValue
	end
	
	-- Returns how many seconds can value be in the MemoryStore, depending on last refresh time
	function LeaderboardSortedMap:_getExpiration()
		local refreshTime = self._refreshTime :: number
		local lastRefreshTime = self._lastRefreshTime :: number
		local currentTime = os.time()

		return refreshTime - (currentTime - lastRefreshTime)
	end
	
	-- Updates a player's entry in the MemoryStore
	function LeaderboardSortedMap:addToPlayerLeaderStat(userId: number, valueToAdd: number)
		local memoryStoreSortedMap = self._memoryStore :: MemoryStoreSortedMap

		pcallUntilSucceed(
			memoryStoreSortedMap.UpdateAsync,
			memoryStoreSortedMap,
			tostring(userId),
			function(value, sortKey)
				local currentTime = os.time()

				if not value then
					value = self._defaultValue
				end
				local newValue = value + valueToAdd
				return newValue, newValue
			end,
			self:_getExpiration()
		)
	end

	function LeaderboardSortedMap:clearAll()
		local memoryStoreSortedMap = self._memoryStore :: MemoryStoreSortedMap

		local itemsCount = 0

		while true do
			local _, items = pcallUntilSucceed(
				memoryStoreSortedMap.GetRangeAsync,
				memoryStoreSortedMap,
				Enum.SortDirection.Ascending,
				200
			)
			itemsCount += #items

			for _, item in items do
				pcallUntilSucceed(memoryStoreSortedMap.RemoveAsync, memoryStoreSortedMap, item.key)
			end

			if #items < 200 then
				break
			end
		end
		return itemsCount
	end
end

local Leaderboards = {}
Leaderboards.STATS = {
	KILLS = "KILLS",
	WINS = "WINS",
}
Leaderboards.PERSONAL_STATS = {
	LOSES = "LOSES",
	KILLS = "KILLS",
	WINS = "WINS",
	RATING = "RATING",
	XP_WIN = "XP_WIN",
	XP_LOSE = "XP_LOSE",
}

Leaderboards[WEEKLY_PREFIX] = {
	[Leaderboards.STATS.KILLS] = LeaderboardSortedMap.new(
		`{Leaderboards.STATS.KILLS}{WEEKLY_PREFIX}`,
		0,
		SECONDS_IN_WEEK
	),
	[Leaderboards.STATS.WINS] = LeaderboardSortedMap.new(
		`{Leaderboards.STATS.WINS}{WEEKLY_PREFIX}`,
		0,
		SECONDS_IN_WEEK
	),
}
Leaderboards[MONTHLY_PREFIX] = {
	[Leaderboards.STATS.KILLS] = LeaderboardSortedMap.new(
		`{Leaderboards.STATS.KILLS}{MONTHLY_PREFIX}`,
		0,
		SECONDS_IN_MONTHS
	),
	[Leaderboards.STATS.WINS] = LeaderboardSortedMap.new(
		`{Leaderboards.STATS.WINS}{MONTHLY_PREFIX}`,
		0,
		SECONDS_IN_MONTHS
	),
}
function Leaderboards:clearAll()
	local itemsCount = 0

	for leaderboardName, leaderboard in pairs(Leaderboards[WEEKLY_PREFIX]) do
		itemsCount += leaderboard:clearAll()
	end
	for leaderboardName, leaderboard in pairs(Leaderboards[MONTHLY_PREFIX]) do
		itemsCount += leaderboard:clearAll()
	end

	return itemsCount
end

do
	local function updateGlobal(userId: number, prefix: string)
		local player = Players:GetPlayerByUserId(userId)
		local dataFolder = player.Data :: Folder
		
		for leaderboardName, leaderboard in pairs(Leaderboards[prefix]) do
			local numberValue = dataFolder:FindFirstChild(leaderboardName) :: NumberValue
			leaderboard:addToPlayerLeaderStat(userId, numberValue.Value)
		end
	end
	
	function Leaderboards:addPlayerStatsToLeaderboards(userId: number)
		updateGlobal(userId, WEEKLY_PREFIX)
		updateGlobal(userId, MONTHLY_PREFIX)
	end
end

local function updateLeaderboards(prefix: string, updatePeriod: number)
	local _, lastRefresh = pcallUntilSucceed(
		LeaderboardsResetTimeMemoryStore.GetAsync,
		LeaderboardsResetTimeMemoryStore,
		prefix
	)
	lastRefresh = lastRefresh or 0
	
	for _, leaderboard in pairs(Leaderboards[prefix]) do
		leaderboard._lastRefreshTime = lastRefresh
	end
	-- Checks if last refresh time expired already
	if os.time() - lastRefresh < updatePeriod then
		return
	end
	-- Updating refresh time
	LeaderboardsResetTimeMemoryStore:UpdateAsync(prefix, function(value, sortKey)
		if not value then
			value = 0
		end
		local currentTime = os.time()
		if currentTime - value < updatePeriod then
			return nil
		end
		return currentTime, sortKey
	end, updatePeriod)
end

task.spawn(function()
	while true do
		updateLeaderboards(WEEKLY_PREFIX, SECONDS_IN_WEEK)
		updateLeaderboards(MONTHLY_PREFIX, SECONDS_IN_MONTHS)
		
		task.wait(2)
	end
end)

return Leaderboards
