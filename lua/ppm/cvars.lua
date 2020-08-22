local FCVAR_ARCHIVE_REPLICATED=FCVAR_REPLICATED
if SERVER then
	FCVAR_ARCHIVE_REPLICATED=bit.bor(FCVAR_REPLICATED,FCVAR_ARCHIVE)
end
PPM.height_min=CreateConVar("ppm_height_min","0",FCVAR_ARCHIVE_REPLICATED,"minimum for leg and neck scaling",-4,.99):GetFloat()or 0
PPM.height_max=CreateConVar("ppm_height_max","3",FCVAR_ARCHIVE_REPLICATED,"maximum for leg and neck scaling",1.01,7):GetFloat()or 3
if SERVER then
	util.AddNetworkString"ppm_height"
	cvars.AddChangeCallback("ppm_height_min",function(v,o,n)
		n=tonumber(n)or 0
		PPM.height_min=n
		net.Start"ppm_height"
		net.WriteFloat(n)
		net.WriteBool(false)
		net.Broadcast()
	end,"ppm_height")
	cvars.AddChangeCallback("ppm_height_max",function(v,o,n)
		n=tonumber(n)or 3
		PPM.height_max=n
		net.Start"ppm_height"
		net.WriteFloat(n)
		net.WriteBool(true)
		net.Broadcast()
	end,"ppm_height")
else
	net.Receive("ppm_height",function(len,ply)
		local n=net.ReadFloat()
		if net.ReadBool()then
			PPM.height_max=n
			PPM.Editor3_nodes.pony_normal_body.body.controlls[5].max=n
			PPM.Editor3_nodes.pony_normal_body.body.controlls[6].max=n
		else
			PPM.height_min=n
			PPM.Editor3_nodes.pony_normal_body.body.controlls[5].min=n
			PPM.Editor3_nodes.pony_normal_body.body.controlls[6].min=n
		end
	end)
end
PPM.scale_min=CreateConVar("ppm_scale_min",".5",FCVAR_ARCHIVE_REPLICATED,"minimum for model scaling",.01,.99):GetFloat()or .5
PPM.scale_max=CreateConVar("ppm_scale_max","1.5",FCVAR_ARCHIVE_REPLICATED,"maximum for model scaling",1.01,4):GetFloat()or 1.5
if SERVER then
	util.AddNetworkString"ppm_scale"
	cvars.AddChangeCallback("ppm_scale_min",function(v,o,n)
		n=tonumber(n)or .5
		PPM.scale_min=n
		net.Start"ppm_scale"
		net.WriteFloat(n)
		net.WriteBool(false)
		net.Broadcast()
		for k,v in ipairs(ents.GetAll())do
			if PPM.isValidPonyLight(v)then
				PPM.SetModelScale(v)
			end
		end
	end,"ppm_scale")
	cvars.AddChangeCallback("ppm_scale_max",function(v,o,n)
		n=tonumber(n)or 2
		PPM.scale_max=n
		net.Start"ppm_scale"
		net.WriteFloat(n)
		net.WriteBool(true)
		net.Broadcast()
		for k,v in ipairs(ents.GetAll())do
			if PPM.isValidPonyLight(v)then
				PPM.SetModelScale(v)
			end
		end
	end,"ppm_scale")
else
	net.Receive("ppm_scale",function(len,ply)
		local n=net.ReadFloat()
		if net.ReadBool()then
			PPM.scale_max=n
			PPM.Editor3_nodes.pony_normal_body.body.controlls[7].max=n
		else
			PPM.scale_min=n
			PPM.Editor3_nodes.pony_normal_body.body.controlls[7].min=n
		end
	end)
end
