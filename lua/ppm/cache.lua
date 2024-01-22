
PPM.CacheGroups = { OC_DATA = 0, PONY_MARK = 1 }
PPM.CacheTransferOptions = PPM.CacheTransferOptions or { PACKET_SIZE = 1024, PACKET_DELAY = 2, CLIENT_TIMEOUT = 600, UPDATE_DELAY = 300, OC_COUNT = 30, RETRY_LIMIT = 10 }
PPM.MessageNames = { INITIAL_SERVER_UPDATE = 0, ITEM_REQUEST = 1, ITEM_PAYLOAD = 2 }
-- Entry Format: entity => { [1] = sig, [2] = parsed data (OC) or data (MARK) }
PPM.PonyData = PPM.PonyData or {}
PPM.MarkData = PPM.MarkData or {}
PPM.timerInc = PPM.timerInc or 1

-- Create a modified version of the built in CRC to force inclusion of null characters
local CHAR_1=string.char(1)
function PPM.DataCRC(data)
	local CRC=util.CRC(data:Replace("\0",CHAR_1))
	return CRC
end

function PPM.SaveToCache(group, ply, name, data, skipNameResolve)
	-- Determine the player's id, accounting for single player
	local id

	if type(ply) == "string" then
		id = ply
	elseif not game.SinglePlayer() or CLIENT then
		if not IsValid(ply) then
			error("PPM.SaveToCache was called with an invalid entity")
		elseif not ply:IsPlayer() then
			error("PPM.SaveToCache was called with a non-player entity")
		elseif not ply.SteamID64 then
			error("PPM.SaveToCache was called during startup")
		else
			id = ply:SteamID64()
		end
	end

	if id == nil then
		id = PPM.SteamID64(ply) or "0"
	end

	-- Determine the target director and create the signature
	local dir = "ppm_cache/" .. tonumber(group) .. "/" .. id .. "/"
	local sig = PPM.DataCRC(data) .. "."

	if skipNameResolve then
		sig = sig .. name
	else
		sig = sig .. PPM.DataCRC(name)
	end

	-- Create the directory if it doesn't already exist and store the contents in it with the id of the owning player for verification purposes
	file.CreateDir(dir)
	file.Write(dir .. sig .. ".txt", util.Compress(string.char(string.len(id)) .. id .. data))
	-- Return the signature

	return sig
end

function PPM.LoadFromCache(group, ply, sig)
	-- Determine the player's id, accounting for single player
	local id

	if type(ply) == "string" then
		id = ply
	elseif not game.SinglePlayer() or CLIENT then
		if not IsValid(ply) then
			id = "0" ErrorNoHalt("PPM.LoadFromCache was called with an invalid entity")
		elseif not ply:IsPlayer() then
			id = "0" ErrorNoHalt("PPM.LoadFromCache was called with a non-player entity")
		elseif not ply.SteamID64 then
			error("PPM.LoadFromCache was called during startup")
		else
			id = ply:SteamID64()
		end
	end

	if id == nil then
		id = "0"
	end

	-- Make sure the signature is valid
	local sigParts = string.Split(sig, ".")

	if table.Count(sigParts) ~= 2 then
		error("Invalid signature given")
	end

	-- Determine the target directory
	local dir = "ppm_cache/" .. tonumber(group) .. "/" .. id .. "/"
	-- Load the data from the file and quit if it doesn't exist or otherwise errors out
	local rawData = file.Read(dir .. sig .. ".txt")
	if not rawData then return end
	-- Decompress and interpret the data
	rawData = util.Decompress(rawData)

	if not rawData then
		file.Delete(dir .. sig .. ".txt")
		ErrorNoHalt("Invalid file detected and deleted: " .. dir .. sig .. ".txt")

		return
	end

	local idLen = string.byte(rawData)

	if id ~= string.sub(rawData, 2, idLen + 1) then
		file.Delete(dir .. sig .. ".txt")
		ErrorNoHalt("Invalid file detected and deleted: " .. dir .. sig .. ".txt")

		return
	end

	local data = string.sub(rawData, idLen + 2)

	if sigParts[1] ~= PPM.DataCRC(data) then
		file.Delete(dir .. sig .. ".txt")
		ErrorNoHalt("Invalid file detected and deleted: " .. dir .. sig .. ".txt")

		return
	end

	return data
end

function PPM.GetResolvedName(sig)
	local perPos = string.find(sig, ".", 1, true)

	return string.sub(sig, perPos + 1)
end

function PPM.UIntToString(val, byteCount)
	val = math.floor(math.abs(val))
	local chars = {}

	for i = 1, byteCount do
		chars[i] = string.char(val % 256)
		val = math.floor(val / 256)
	end

	return string.reverse(table.concat(chars))
end

function PPM.StringToUInt(str, byteCount)
	local val = 0

	for i = 1, byteCount do
		val = (val * 256) + string.byte(str, i)
	end

	return val
end

--[[function PrintData( data, prefix )
	local i = -1
	local filename
	repeat
		i = i + 1
		filename = prefix .. "." .. i .. ".txt"
	until not file.Exists( filename, "DATA" )
	file.Write( filename, data )
end]]
function PPM.TransmitMessage(payload, ply)
	--PrintData(payload, "output" )
	if PPM.OutgoingMessage ~= nil then return end
	local parts = {}
	payload = util.Compress(payload)
	local partCount = math.ceil(string.len(payload) / PPM.CacheTransferOptions.PACKET_SIZE)

	if SERVER and cvars.Bool("ppm_logcache") and IsValid(ply) then
		ServerLog("Transmitting data. Size: " .. string.len(payload) .. " Parts: " .. partCount .. " To: " .. tostring(ply) .. "\n")
	end

	if partCount <= 0 then return end
	-- Split it into parts for transmission
	local offset = 1

	for i = 1, partCount - 1 do
		parts[i] = string.sub(payload, offset, offset + PPM.CacheTransferOptions.PACKET_SIZE - 1)
		offset = offset + PPM.CacheTransferOptions.PACKET_SIZE
	end

	parts[partCount] = string.sub(payload, offset)
	parts.nextPacketNum = 1
	parts.ply = ply
	PPM.OutgoingMessage = parts
	-- Transmit the first part right away
	PPM.TransmitMessagePart(partCount)
	-- Create a timer (extra repetition will attempt to start a new transmission if possible, keeps delay between transfers intact)
	PPM.timerInc = PPM.timerInc + 1 -- Exists to fix the fact that timers with multiple repetitions fail if they don't have a unique name every time
	timer.Create("PonyTransferTimer" .. tostring(PPM.timerInc), PPM.CacheTransferOptions.PACKET_DELAY, partCount, PPM.TransmitMessagePart)
end

-- Note: partCount is only passed in on the first message
function PPM.TransmitMessagePart(partCount)
	if PPM.OutgoingMessage == nil then
		PPM.TryNewTransfer()
	end

	local nextPacket = PPM.OutgoingMessage[PPM.OutgoingMessage.nextPacketNum]
	PPM.OutgoingMessage.nextPacketNum = PPM.OutgoingMessage.nextPacketNum + 1

	if not nextPacket or (SERVER and not IsValid(PPM.OutgoingMessage.ply)) then
		PPM.OutgoingMessage = nil
		PPM.TryNewTransfer()
		-- send next packet
	else
		if SERVER and cvars.Bool("ppm_logcache") then
			ServerLog("Transmitting packet number " .. PPM.OutgoingMessage.nextPacketNum - 1 .. " to " .. tostring(PPM.OutgoingMessage.ply) .. "\n")
		end

		net.Start("ppm_message")
		net.WriteUInt(1, 2)
		net.WriteBit(partCount == nil)

		if partCount ~= nil then
			net.WriteUInt(partCount, 16)
		end

		net.WriteUInt(string.len(nextPacket), 16)
		net.WriteData(nextPacket, string.len(nextPacket))

		if SERVER then
			net.Send(PPM.OutgoingMessage.ply)
		else
			net.SendToServer()
		end
	end -- no packets left to send or player left, clean up and try to start a new transfer
end

-- ply will be nil when not called on the server
function PPM.HandleMessage(payload, ply)
	local response = {0}
	--PrintData(payload, "input")
	local messageCount = string.byte(payload, 1)
	local offset = 2 -- increment after read

	for i = 1, messageCount do
		local messageType = string.byte(payload, offset)
		local messageHandler = PPM.MessageHandlers[messageType]

		if not messageHandler then
			ErrorNoHalt("Invalid PPM message type detected")

			return
		end

		offset = offset + 1
		local offsetAdd, responseAdd = messageHandler(payload, offset, ply)
		offset = offset + (offsetAdd or 0)

		-- Add one to the message count if needed and add the message section to the response
		if SERVER then
			if responseAdd then
				response[1] = response[1] + 1
			end

			response[i + 1] = responseAdd or ""
		end
	end

	if SERVER then
		response[1] = string.char(response[1])

		return table.concat(response)
	end
end

if SERVER then
	util.AddNetworkString("ppm_message")
	CreateConVar("ppm_logcache", "0", 0)
	PPM.PartialIncomingMessages = PPM.PartialIncomingMessages or {}
	PPM.WaitingIncomingMessages = PPM.WaitingIncomingMessages or {}

	function PPM.HandleNetMessage(len, ply)
		local msgType = net.ReadUInt(2)
		if msgType == 0 then
			local sig = net.ReadString()
			local sid64 = nil
			if game.SinglePlayer() then
				sid64=net.ReadString()
			end
			local data = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, sid64 or ply, sig)
			if data then
				data = PPM.StringToPonyData(data)

				--PPM.PonyData[ply] = { sig, PPM.StringToPonyData( data ) }
				--PPM.UpdateSignature( ply, sig )
				--PPM.setBodygroups( ply )
				if data.custom_mark then
					data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, sid64 or ply, data.custom_mark)
					
					if data then
						--PPM.MarkData[ply] = { PPM.PonyData[ply][2].custom_mark, data }
						PPM.UpdateSignature(ply,sig,nil,sid64)
						PPM.setBodygroups(ply)
						PPM.SetModelScale(ply)
					else
						PPM.MarkData[ply] = nil
						PPM.RequestItem(true,ply)
					end
				else
					PPM.UpdateSignature(ply,sig,nil,sid64)
					PPM.setBodygroups(ply)
					PPM.SetModelScale(ply)
				end
			else
				PPM.RequestItem(false, ply)
			end
			-- transfer
			-- new transfer
			-- continuing transfer
			-- client timeout checkup
			-- Check the outgoing message data
		elseif msgType == 1 then
			if net.ReadBit() == 0 then
				PPM.PartialIncomingMessages[ply] = {
					packetCount = net.ReadUInt(16)
				}

				local bodySize = net.ReadUInt(16)
				table.insert(PPM.PartialIncomingMessages[ply], net.ReadData(bodySize))
			else
				if not PPM.PartialIncomingMessages[ply] then return end
				local bodySize = net.ReadUInt(16)
				table.insert(PPM.PartialIncomingMessages[ply], net.ReadData(bodySize))
			end

			PPM.PartialIncomingMessages[ply].packetCount = PPM.PartialIncomingMessages[ply].packetCount - 1

			if SERVER and cvars.Bool("ppm_logcache") then
				ServerLog("Received packet from " .. tostring(ply) .. ". " .. PPM.PartialIncomingMessages[ply].packetCount .. " Remaining\n")
			end

			if PPM.PartialIncomingMessages[ply].packetCount <= 0 then
				PPM.HandleTransferComplete(ply)
			end
		elseif msgType == 3 then
			PPM.SendTimeoutResponse(ply, not PPM.IsPlayerInQueue(ply))
		end -- broadcast

		PPM.TryNewTransfer()
	end

	function PPM.IsPlayerInQueue(ply)
		if PPM.OutgoingMessage and PPM.OutgoingMessage.ply == ply then
			return true
		elseif PPM.PartialIncomingMessages[ply] then
			return true
		else
			for k, v in pairs(PPM.WaitingIncomingMessages) do
				if not IsValid(v[1]) then
					table.remove(PPM.WaitingIncomingMessages, k)
				elseif v[1] == ply then
					return true
				end
			end
		end

		return false
	end

	function PPM.SendTimeoutResponse(ply, response)
		net.Start("ppm_message")
		net.WriteUInt(3, 2)
		net.WriteBit(response)
		net.Send(ply)
	end

	-- Only send this if the server has cached it, will always indicate an OC since marks sigs are embedded in OCs
	function PPM.UpdateSignature(ent, sig, cacheTarget,sid64)
		if not IsValid(ent) then return end
		if PPM.PonyData[ent] and PPM.PonyData[ent][1] == sig then return end -- prevent duplicate updates (aka spamming the Apply button)
		local id = ent

		if ent:IsPlayer() then
			id = ent
			if game.SinglePlayer() then
				id=sid64
			end
		else
			id = cacheTarget or ent.ponyCacheTarget
		end
		local data = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, id, sig)
		if not data then return end
		PPM.PonyData[ent] = {sig, PPM.StringToPonyData(data)}
		local markSig = PPM.PonyData[ent][2].custom_mark

		if markSig then
			local data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, id, markSig)

			if data then
				PPM.MarkData[ent] = {markSig, data}
			end
		end

		net.Start("ppm_message")
		net.WriteUInt(0, 2)
		net.WriteString(sig)
		net.WriteEntity(ent)

		if cacheTarget then
			net.WriteString(cacheTarget)
		end

		net.Broadcast()
		hook.Call("OnPonyChanged", nil, ent, PPM.PonyData[ent][2]) --Called here because a pony counts as changed when it is resent to EVERYONE

		if cvars.Bool("ppm_logcache") then
			ServerLog("Signature update sent for " .. tostring(ent) .. "\n")
		end
	end

	-- Request a pony oc or mark
	function PPM.RequestItem(mark, ply)
		if not IsValid(ply) then return end
		net.Start("ppm_message")
		net.WriteUInt(2, 2)
		net.WriteBit(mark)
		net.Send(ply)
	end

	function PPM.HOOK_EntityRemoved(ent)
		PPM.PonyData[ent] = nil
		PPM.MarkData[ent] = nil
		if not ent:IsPlayer() then return end
		PPM.PartialIncomingMessages[ent] = nil
		-- Don't need to check the waiting list since they will just be thrown out when its their turn
	end

	function PPM.HOOK_PlayerDeath(ply)
		if not PPM.IsPlayerInQueue(ply) then
			table.insert(PPM.WaitingIncomingMessages, {ply, string.char(1, PPM.MessageNames.INITIAL_SERVER_UPDATE)})
			PPM.TryNewTransfer()
		end
	end

	hook.Add("PlayerDeath", "ponyPlayerDeath", PPM.HOOK_PlayerDeath)

	-- Priority 4 = Nothing
	-- Priority 3 = Mark Data
	-- Priority 2 = OC Data (and anything else)
	-- Priority 1 = Initial Server Message
	function PPM.ChooseNextTransfer()
		local priority = 4
		local transferKey = nil

		for k, v in ipairs(PPM.WaitingIncomingMessages) do
			-- Identify the message priority ( we can determine this from looking at the type of the first message )
			local currentPriority = 2
			local firstMessage, group = string.byte(v[2], 2, 3)

			if firstMessage == PPM.MessageNames.INITIAL_SERVER_UPDATE then
				currentPriority = 1
			elseif firstMessage == PPM.MessageNames.ITEM_REQUEST and group == PPM.CacheGroups.PONY_MARK then
				currentPriority = 3
			end

			if currentPriority < priority then
				transferKey = k
				priority = currentPriority
				if priority == 1 then break end
			end
		end

		if transferKey then return table.remove(PPM.WaitingIncomingMessages, transferKey) end
	end

	function PPM.TryNewTransfer()
		if PPM.OutgoingMessage ~= nil then return end
		local message = PPM.ChooseNextTransfer()
		if not message then return end
		if not IsValid(message[1]) then return end -- make sure player is still valid
		local response = PPM.HandleMessage(message[2], message[1])
		if not response then return end -- stop here if no responses were given to the requests from the client
		PPM.TransmitMessage(response, message[1])
	end

	function PPM.HandleTransferComplete(ply)
		-- Throw the message onto the queue for processing when it becomes its turn
		PPM.PartialIncomingMessages[ply].packetCount = nil
		local data = util.Decompress(table.concat(PPM.PartialIncomingMessages[ply]))

		if data then
			table.insert(PPM.WaitingIncomingMessages, {ply, data})
		end

		PPM.PartialIncomingMessages[ply] = nil
	end

	PPM.MessageHandlers = PPM.MessageHandlers or {}

	PPM.MessageHandlers[PPM.MessageNames.INITIAL_SERVER_UPDATE] = function(payload, offset, ply)
		-- Give newly connecting clients all the currently active signatures and let them request them as needed
		local msg = {""} -- message data with placeholder in first slot
		local PonyCount = 0

		for k, v in pairs(PPM.PonyData) do
			if IsValid(k) then
				if k:IsPlayer() or not k.ponyCacheTarget then
					table.insert(msg, PPM.UIntToString(k:EntIndex(), 2) .. string.char(string.len(v[1]), 0) .. v[1])
				else
					table.insert(msg, PPM.UIntToString(k:EntIndex(), 2) .. string.char(string.len(v[1]), string.len(k.ponyCacheTarget)) .. v[1] .. k.ponyCacheTarget)
				end

				PonyCount = PonyCount + 1
			else
				PPM.PonyData[k] = nil
			end
		end

		local MarkCount = 0

		for k, v in pairs(PPM.MarkData) do
			if IsValid(k) then
				table.insert(msg, PPM.UIntToString(k:EntIndex(), 2) .. string.char(string.len(v[1])) .. v[1])
				MarkCount = MarkCount + 1
			else
				PPM.MarkData[k] = nil
			end
		end

		msg[1] = string.char(PPM.MessageNames.INITIAL_SERVER_UPDATE, PonyCount, MarkCount)
		msg = table.concat(msg)

		return 0, msg
	end

	PPM.MessageHandlers[PPM.MessageNames.ITEM_REQUEST] = function(payload, offset, ply)
		-- Parse the request
		local group, idSize, sigSize = string.byte(payload, offset, offset + 2)
		offset = offset + 3
		local id = string.sub(payload, offset, offset + idSize - 1)
		offset = offset + idSize
		local sig = string.sub(payload, offset, offset + sigSize - 1)
		offset = offset + sigSize

		-- Don't send a message back if the data is somehow not available
		if SERVER and cvars.Bool("ppm_logcache") then
			ServerLog("Item " .. sig .. " requested for " .. tostring(ply) .. "\n")
		end

		local data = PPM.LoadFromCache(group, id, sig)
		if not data then return 3 + idSize + sigSize end
		-- Otherwise create the response and send it
		sig = PPM.GetResolvedName(sig) -- the client only cares about part of the signature
		local msg = string.char(PPM.MessageNames.ITEM_REQUEST, group, string.len(id), string.len(sig)) .. PPM.UIntToString(string.len(data), 4) .. id .. sig .. data

		return 3 + idSize + sigSize, msg
	end

	PPM.MessageHandlers[PPM.MessageNames.ITEM_PAYLOAD] = function(payload, offset, ply)
		local isOC = string.byte(payload, offset) == 0
		offset = offset + 1
		local sigNameSize = string.byte(payload, offset)
		offset = offset + 1
		local ocSigSize -- get the OC sig for the update if needed

		if not isOC then
			ocSigSize = string.byte(payload, offset)
			offset = offset + 1
		end

		local size = PPM.StringToUInt(string.sub(payload, offset, offset + 3), 4)
		offset = offset + 4
		local sigName = string.sub(payload, offset, offset + sigNameSize - 1)
		offset = offset + sigNameSize
		local ocSig

		if not isOC then
			ocSig = string.sub(payload, offset, offset + ocSigSize - 1)
			offset = offset + ocSigSize
		end

		local data = string.sub(payload, offset, offset + size - 1)

		if isOC then
			local sig = PPM.SaveToCache(PPM.CacheGroups.OC_DATA, ply, sigName, data, true)
			local ponydata = PPM.StringToPonyData(data)

			if ponydata.custom_mark then
				local markData = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, ply, ponydata.custom_mark)

				if markData then
					--PPM.MarkData[ply] = { PPM.PonyData[ply][2].custom_mark, markData }
					PPM.UpdateSignature(ply, sig)
					PPM.setBodygroups(ply)
					PPM.SetModelScale(ply)
				else
					PPM.RequestItem(true, ply)
				end
			else
				PPM.UpdateSignature(ply, sig)
				PPM.setBodygroups(ply)
				PPM.SetModelScale(ply)
			end
			-- Mark
			-- verify the signature
			--PPM.MarkData[ply] = { sig, data }

			return sigNameSize + size + 6
		else
			local sig = PPM.SaveToCache(PPM.CacheGroups.PONY_MARK, ply, sigName, data, true)
			local ocData = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, ply, ocSig)
			local ponydata = PPM.StringToPonyData(ocData)

			if ponydata.custom_mark == sig then
				PPM.UpdateSignature(ply, ocSig)
				PPM.setBodygroups(ply)
				PPM.SetModelScale(ply)
			else
				PPM.RequestItem(true, ply)
			end

			return sigNameSize + ocSigSize + size + 7
		end
	end
	-- CLIENT
	-- Whether to send the client's current OC in the next transfer
	-- Whether to sent the client's current ponymark in the next transfer
	-- broadcast
	-- remove any requests already waiting in the queue for resolution on this entity to prevent a race condition
	-- try to resolve
	-- Put any item missing from cache in back of line for retrievals
	-- transfer
	-- new transfer
	-- continuing transfer
	-- OC or Mark request for next transfer
	-- OC
	-- mark
	-- client timeout checkup response
	-- Everything is fine, restart timer
	-- Server confirms our worst fears, panic then let it start over the function call at the end
	-- prevent duplicate updates (aka spamming the Apply button)
	-- Prevent reading from empty list or looping around during the same interation
	-- entry[1] = entity, entry[2] = sig
	-- Get the id
	-- Check if the item has been added to the cache already (and resolve it if it has)
	-- Put in a request for this entry
	-- Cycle entry to back of table
	-- Only ask for Pony marks if we aren't doing anything else in this request
	-- entry[1] = entity, entry[2] = sig
	-- Get the id
	-- Check if the item has been added to the cache already (and resolve it if it has)
	-- Put in a request for this entry
	-- Cycle entry to back of table
	-- See if there is anything to transmit
	-- Start the new transmission
	-- Prevent any new transmissions til the server responds to this one
	-- Break down from loneliness and ask the server "Did you forget about me?"
	-- Verify a message has been received and clear the packetCount index
	-- Join the message parts and verify the message is valid
	-- Timer here for final entity initialization to take place right after this hook ends
	-- Let the server know the client is ready for its initial burst
	-- Retrieve the pony data
	-- Retrieve the mark data
	-- Ignore anything already resolved via a different method
	-- Ignore anything currently waiting to be resolved
	-- Resolve all cache targets
	-- Try to resolve or queue everything that's left
	-- Put any item missing from cache in back of line for retrievals
	-- Parse the response
	-- Save the data to the cache
	-- Make sure the image is a png
	-- Load the material and check if its an error
	-- Grab the texture
	-- Grab the actual width and height to determine scaling
	-- 262144 = 256 * 256 * 4
else
	PPM.UnsatisfiedOCSignatures = PPM.UnsatisfiedOCSignatures or {}
	PPM.UnsatisfiedMarkSignatures = PPM.UnsatisfiedMarkSignatures or {}
	PPM.IncomingMessage = PPM.IncomingMessage or false
	PPM.OCRequested = false
	PPM.MarkRequested = false

	function PPM.HandleNetMessage(len)
		local msgType = net.ReadUInt(2)

		if msgType == 0 then
			local sig = net.ReadString()
			local ent = net.ReadEntity()
			if not IsValid(ent) then return end

			if ent:IsPlayer() then
				id = ent
			else
				id = net.ReadString()
				ent.ponyCacheTarget = id
			end

			for k, v in pairs(PPM.UnsatisfiedOCSignatures) do
				if v[1] == ent then
					table.remove(PPM.UnsatisfiedOCSignatures, k)
				end
			end

			for k, v in pairs(PPM.UnsatisfiedMarkSignatures) do
				if v[1] == ent then
					table.remove(PPM.UnsatisfiedMarkSignatures, k)
				end
			end

			local data = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, id, sig)

			if data then
				PPM.PonyData[ent] = {sig, PPM.StringToPonyData(data)}

				if PPM.PonyData[ent][2].custom_mark then
					data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, id, PPM.PonyData[ent][2].custom_mark)

					if data then
						PPM.MarkData[ent] = {PPM.PonyData[ent][2].custom_mark, data}
					else
						PPM.MarkData[ent] = nil
						table.insert(PPM.UnsatisfiedMarkSignatures, {ent, PPM.PonyData[ent][2].custom_mark})
					end
				end
			else
				table.insert(PPM.UnsatisfiedOCSignatures, {ent, sig})
			end
		elseif msgType == 1 then
			timer.Remove("PonyTimeoutTimer")

			if net.ReadBit() == 0 then
				PPM.IncomingMessage = {
					packetCount = net.ReadUInt(16)
				}

				local bodySize = net.ReadUInt(16)
				table.insert(PPM.IncomingMessage, net.ReadData(bodySize))
			else
				if not PPM.IncomingMessage then return end
				local bodySize = net.ReadUInt(16)
				table.insert(PPM.IncomingMessage, net.ReadData(bodySize))
			end

			PPM.IncomingMessage.packetCount = PPM.IncomingMessage.packetCount - 1

			if PPM.IncomingMessage.packetCount <= 0 then
				PPM.HandleTransferComplete()
			end
		elseif msgType == 2 then
			if net.ReadBit() == 0 then
				PPM.OCRequested = true
			else
				PPM.MarkRequested = true
			end
		elseif msgType == 3 then
			if net.ReadBit() == 0 then
				timer.Remove("PonyTimeoutTimer")
				timer.Create("PonyTimeoutTimer", PPM.CacheTransferOptions.CLIENT_TIMEOUT, 1, PPM.TransferTimeout)
			else
				ErrorNoHalt("PPM Transfer timeout triggered. Attempting retry...")
				PPM.IncomingMessage = nil
			end
		end

		PPM.TryNewTransfer()
	end

	function PPM.UpdateSignature(sig)
		if PPM.PonyData[LocalPlayer()] and PPM.PonyData[LocalPlayer()][1] == sig then return end
		local data = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, LocalPlayer(), sig)
		if not data then return end
		PPM.PonyData[LocalPlayer()] = {sig, PPM.StringToPonyData(data)}
		local markSig = PPM.PonyData[LocalPlayer()][2].custom_mark

		if markSig then
			local data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, LocalPlayer(), markSig)

			if data then
				PPM.MarkData[LocalPlayer()] = {markSig, data}
			else
				PPM.PonyData[LocalPlayer()][2].custom_mark = nil
				sig = PPM.Save("_current.txt", PPM.PonyData[LocalPlayer()][2])
			end
		end

		net.Start("ppm_message")
		net.WriteUInt(0, 2)
		net.WriteString(sig)
		if game.SinglePlayer() then
			net.WriteString(LocalPlayer():SteamID64())
		end
		net.SendToServer()
	end

	function PPM.TryNewTransfer()
		if PPM.IncomingMessage ~= nil or PPM.OutgoingMessage ~= nil then return end

		if not PPM.InitialMessage then
			local message = string.char(1, PPM.MessageNames.INITIAL_SERVER_UPDATE)
			PPM.TransmitMessage(message)
			PPM.IncomingMessage = false
			timer.Remove("PonyTimeoutTimer")
			timer.Create("PonyTimeoutTimer", PPM.CacheTransferOptions.CLIENT_TIMEOUT, 1, PPM.TransferTimeout)
		end

		local messageParts = {0}
		local currentMessage

		if not PPM.PonyData[LocalPlayer()] then
			PPM.LOAD()
		end

		if PPM.OCRequested then
			local ponyData = PPM.PonyData[LocalPlayer()]
			local ocData = PPM.PonyDataToString(ponyData[2])
			local sigName = PPM.GetResolvedName(ponyData[1])
			currentMessage = string.char(PPM.MessageNames.ITEM_PAYLOAD, 0, string.len(sigName)) .. PPM.UIntToString(string.len(ocData), 4) .. sigName .. ocData
			messageParts[1] = messageParts[1] + 1
			messageParts[messageParts[1] + 1] = currentMessage
			PPM.OCRequested = false
		end

		if PPM.MarkRequested then
			local markData = PPM.MarkData[LocalPlayer()]

			if markData then
				local sigName = PPM.GetResolvedName(markData[1])
				currentMessage = string.char(PPM.MessageNames.ITEM_PAYLOAD, 1, string.len(sigName), string.len(PPM.PonyData[LocalPlayer()][1])) .. PPM.UIntToString(string.len(markData[2]), 4) .. sigName .. PPM.PonyData[LocalPlayer()][1] .. markData[2]
				messageParts[1] = messageParts[1] + 1
				messageParts[messageParts[1] + 1] = currentMessage
			end

			PPM.MarkRequested = false
		end

		local initialEntry = nil

		while messageParts[1] < PPM.CacheTransferOptions.OC_COUNT do
			local entry = PPM.UnsatisfiedOCSignatures[1]
			if not entry then break end
			if entry == initialEntry then break end

			if not initialEntry then
				initialEntry = entry
			end

			if not IsValid(entry[1]) then
				table.remove(PPM.UnsatisfiedOCSignatures, 1)
			else
				local id

				if entry[1]:IsPlayer() then
					id = entry[1]:SteamID64() or PPM.SteamID64(entry[1])
				else
					id = entry[1].ponyCacheTarget
				end

				local data = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, id, entry[2])

				if data then
					PPM.PonyData[entry[1]] = {entry[2], PPM.StringToPonyData(data)}

					if PPM.PonyData[entry[1]][2].custom_mark then
						data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, id, PPM.PonyData[entry[1]][2].custom_mark)

						if data then
							PPM.MarkData[entry[1]] = {PPM.PonyData[entry[1]][2].custom_mark, data}
						else
							PPM.MarkData[entry[1]] = nil
							table.insert(PPM.UnsatisfiedMarkSignatures, {entry[1], PPM.PonyData[entry[1]][2].custom_mark})
						end
					end

					table.remove(PPM.UnsatisfiedOCSignatures, 1)
				else
					if not entry[3] then
						entry[3] = 0
					end

					if entry[3] >= PPM.CacheTransferOptions.RETRY_LIMIT then
						table.remove(PPM.UnsatisfiedOCSignatures, 1)
					else
						entry[3] = entry[3] + 1
						currentMessage = string.char(PPM.MessageNames.ITEM_REQUEST, PPM.CacheGroups.OC_DATA, string.len(id), string.len(entry[2])) .. id .. entry[2]
						messageParts[1] = messageParts[1] + 1
						messageParts[messageParts[1] + 1] = currentMessage
						table.remove(PPM.UnsatisfiedOCSignatures, 1)
						table.insert(PPM.UnsatisfiedOCSignatures, entry)
					end
				end
			end
		end

		if messageParts[1] < 1 then
			local entry = PPM.UnsatisfiedMarkSignatures[1]
			if not entry then return end

			if not IsValid(entry[1]) then
				table.remove(PPM.UnsatisfiedMarkSignatures, 1)
			else
				local id

				if entry[1]:IsPlayer() then
					id = entry[1]:SteamID64() or PPM.SteamID64(entry[1])
				else
					id = entry[1].ponyCacheTarget
				end

				local data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, id, entry[2])

				if data then
					PPM.MarkData[entry[1]] = {entry[2], data}
					table.remove(PPM.UnsatisfiedMarkSignatures, 1)
				else
					if not entry[3] then
						entry[3] = 0
					end

					if entry[3] >= PPM.CacheTransferOptions.RETRY_LIMIT then
						table.remove(PPM.UnsatisfiedMarkSignatures, 1)
					else
						entry[3] = entry[3] + 1
						currentMessage = string.char(PPM.MessageNames.ITEM_REQUEST, PPM.CacheGroups.PONY_MARK, string.len(id), string.len(entry[2])) .. id .. entry[2]
						messageParts[1] = messageParts[1] + 1
						messageParts[messageParts[1] + 1] = currentMessage
						table.remove(PPM.UnsatisfiedMarkSignatures, 1)
						table.insert(PPM.UnsatisfiedMarkSignatures, entry)
					end
				end
			end
		end

		if messageParts[1] <= 0 then return end
		messageParts[1] = string.char(messageParts[1])
		messageParts = table.concat(messageParts)
		PPM.TransmitMessage(messageParts)
		PPM.IncomingMessage = false
		timer.Remove("PonyTimeoutTimer")
		timer.Create("PonyTimeoutTimer", PPM.CacheTransferOptions.CLIENT_TIMEOUT, 1, PPM.TransferTimeout)
	end

	function PPM.TransferTimeout()
		if PPM.IncomingMessage == false then
			net.Start("ppm_message")
			net.WriteUInt(3, 2)
			net.SendToServer()
		end
	end

	function PPM.RequestUpdate()
		PPM.InitialMessage = false
		PPM.TryNewTransfer()
	end

	function PPM.HandleTransferComplete()
		if not PPM.IncomingMessage or PPM.IncomingMessage.packetCount > 0 then return end
		PPM.IncomingMessage.packetCount = nil
		local payload = util.Decompress(table.concat(PPM.IncomingMessage))
		PPM.IncomingMessage = nil
		if not payload then return end
		PPM.HandleMessage(payload)
	end

	function PPM.HOOK_EntityRemoved(ent)
		PPM.PonyData[ent] = nil
		PPM.MarkData[ent] = nil
	end

	function PPM.HOOK_InitPostEntity()
		timer.Simple(1, function()
			local message = string.char(1, PPM.MessageNames.INITIAL_SERVER_UPDATE)
			PPM.TransmitMessage(message)
			PPM.IncomingMessage = false
			timer.Remove("PonyTimeoutTimer")
			timer.Create("PonyTimeoutTimer", PPM.CacheTransferOptions.CLIENT_TIMEOUT, 1, PPM.TransferTimeout)
			timer.Create("PonyRequestTimer", PPM.CacheTransferOptions.UPDATE_DELAY, 0, PPM.RequestUpdate)
			concommand.Add("ppm_update", PPM.RequestUpdate)
		end)
	end

	hook.Add("InitPostEntity", "pony_initpostentity", PPM.HOOK_InitPostEntity)
	PPM.MessageHandlers = PPM.MessageHandlers or {}

	PPM.MessageHandlers[PPM.MessageNames.INITIAL_SERVER_UPDATE] = function(payload, offset)
		PPM.InitialMessage = true
		local PonyDataCount, MarkDataCount = string.byte(payload, offset, offset + 1)
		local total = 2
		offset = offset + 2
		local PonyData = {}

		for i = 1, PonyDataCount do
			local ent = Entity(PPM.StringToUInt(string.sub(payload, offset, offset + 1), 2))
			offset = offset + 2
			local sigSize = string.byte(payload, offset)
			offset = offset + 1
			local cacheTargetSize = string.byte(payload, offset)
			offset = offset + 1
			local sig = string.sub(payload, offset, offset + sigSize - 1)
			offset = offset + sigSize
			local cacheTarget

			if cacheTargetSize > 0 then
				cacheTarget = string.sub(payload, offset, offset + cacheTargetSize - 1)
				offset = offset + cacheTargetSize
			end

			if IsValid(ent) then
				PonyData[ent] = {sig, cacheTarget}
			end

			total = total + sigSize + cacheTargetSize + 4
		end

		local MarkData = {}

		for i = 1, MarkDataCount do
			local ent = Entity(PPM.StringToUInt(string.sub(payload, offset, offset + 1), 2))
			offset = offset + 2
			local sigSize = string.byte(payload, offset)
			offset = offset + 1
			local sig = string.sub(payload, offset, offset + sigSize - 1)
			offset = offset + sigSize

			if IsValid(ent) then
				MarkData[ent] = sig
			end

			total = total + sigSize + 3
		end

		for k, v in pairs(PPM.PonyData) do
			PonyData[k] = nil
		end

		for k, v in pairs(PPM.MarkData) do
			MarkData[k] = nil
		end

		for k, v in pairs(PPM.UnsatisfiedOCSignatures) do
			PonyData[v[1]] = nil
		end

		for k, v in pairs(PPM.UnsatisfiedMarkSignatures) do
			MarkData[v[1]] = nil
		end

		for k, v in pairs(PonyData) do
			if not k:IsPlayer() then
				k.ponyCacheTarget = PonyData[k][2]
			end

			PonyData[k] = PonyData[k][1]
		end

		for ent, sig in pairs(PonyData) do
			local id

			if ent:IsPlayer() then
				id = ent
			else
				id = ent.ponyCacheTarget
			end

			local data = PPM.LoadFromCache(PPM.CacheGroups.OC_DATA, id, sig)

			if data then
				PPM.PonyData[ent] = {sig, PPM.StringToPonyData(data)}

				if PPM.PonyData[ent][2].custom_mark then
					data = PPM.LoadFromCache(PPM.CacheGroups.PONY_MARK, id, PPM.PonyData[ent][2].custom_mark)

					if data then
						PPM.MarkData[ent] = {PPM.PonyData[ent][2].custom_mark, data}
					else
						PPM.MarkData[ent] = nil
						table.insert(PPM.UnsatisfiedMarkSignatures, {ent, PPM.PonyData[ent][2].custom_mark})
					end
				end
			else
				table.insert(PPM.UnsatisfiedOCSignatures, {ent, sig})
			end
		end

		return total
	end

	PPM.MessageHandlers[PPM.MessageNames.ITEM_REQUEST] = function(payload, offset)
		local group, idSize, sigNameSize = string.byte(payload, offset, offset + 2)
		offset = offset + 3
		local dataSize = PPM.StringToUInt(string.sub(payload, offset, offset + 3), 4)
		offset = offset + 4
		local id = string.sub(payload, offset, offset + idSize - 1)
		offset = offset + idSize
		local sigName = string.sub(payload, offset, offset + sigNameSize - 1)
		offset = offset + sigNameSize
		local data = string.sub(payload, offset, offset + dataSize - 1)
		offset = offset + dataSize
		PPM.SaveToCache(group, id, sigName, data, true)

		return 7 + idSize + sigNameSize + dataSize
	end

	function PPM.ImageToBinary(imageName)
		if string.Right(imageName, 4) ~= ".png" then return end
		local mat = Material(imageName)
		if mat:IsError() then return end
		local tex = mat:GetTexture("$basetexture")
		if not tex then return end
		PPM.mat = mat
		PPM.tex = tex
		local width = tex:Width()
		local height = tex:Height()
		local rgba = {}

		for x = 0, width - 1, width / 256 do
			for y = 0, height - 1, height / 256 do
				local color = tex:GetColor(math.floor(x), math.floor(y))
				table.insert(rgba, string.char(color.r, color.g, color.b, color.a))
			end
		end

		return table.concat(rgba)
	end

	function PPM.BinaryImageToRT(data)
		if string.len(data) ~= 262144 then return end
		render.Clear(0, 0, 0, 0)
		local offset = 1
		local r, g, b, a

		for x = 0, 255 do
			for y = 0, 255 do
				r, g, b, a = string.byte(data, offset, offset + 3)
				offset = offset + 4
				render.DrawQuadEasy(Vector(x, y, 0), Vector(0, 0, -1), 1, 1, Color(r, g, b, a), 0)
			end
		end
	end
end
PPM.SteamID64=function(ply)
	local ret=ply:SteamID64()
	if ret then
		return ret
	end
	return ply:GetNWString("SteamID64","00000000")
end
if game.SinglePlayer() then
	if SERVER then
		util.AddNetworkString"NWSID64"
		hook.Add("PlayerSpawn","NWSID64",function(ply)
			net.Start("NWSID64")
			net.Send(ply)
		end)
		net.Receive("NWSID64",function(len,ply)
			ply:SetNWString("SteamID64",net.ReadString())
		end)
	else
		net.Receive("NWSID64",function()
			net.Start"NWSID64"
			net.WriteString(LocalPlayer():SteamID64())
			net.SendToServer()
		end)
	end
else
	hook.Add("PlayerSpawn","NWSID64",function(ply)
		ply:SetNWString("SteamID64",ply:SteamID64())
	end)
end
net.Receive("ppm_message", PPM.HandleNetMessage)
hook.Add("EntityRemoved", "pony_entityremoved", PPM.HOOK_EntityRemoved)
hook.Add("PlayerDisconnected", "pony_playerdisconnected", PPM.HOOK_EntityRemoved)