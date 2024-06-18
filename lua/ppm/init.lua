PPM=PPM or {}
PPM.serverPonydata=PPM.serverPonydata or {}
PPM.isLoaded=false
include("cvars.lua")
include("cache.lua")
include("items.lua")
include("variables.lua")
include("pony_player.lua")
include("resources.lua")
include("preset.lua")
include("gui_toolpanel.lua")
--include("net.lua")
include("ccmark_sys.lua")
include("admin.lua")
include("readme.lua")
include("chatcommands.lua")

include("draw_text.lua")
include("disguise.lua")
if CLIENT then   
	include("render_texture.lua")
	include("render.lua")
	include("bonesystem.lua")
	include("editor3.lua")
	include("editor3_body.lua")
	include("editor3_presets.lua")
	include("presets_base.lua")
	include("gui_toolpanel.lua")
	CreateConVar("ppm_hide_weapon","0",FCVAR_REPLICATED,"hide weapons held by ponies")
	CreateConVar("ppm_enable_camerashift","1",FCVAR_REPLICATED,"Enables ViewOffset Setup")
else
	include("serverside.lua")
end
local I,O=file.Find("ppm/custom_scripts/*.lua","LUA")
local autorefresh={
--	["sh_pony_debug.lua"]=true,
--	["sv_pony_hull.lua"]=true,
}
for v in SortedPairs(autorefresh)do
	if v:StartWith"cl_"and CLIENT--clientside only
	or v:StartWith"sv_"and SERVER--serverside only
	or v:StartWith"sh_"then--shared
		MsgN("ppm/custom_scripts/",v)
		include("ppm/custom_scripts/"..v)
	end
end
for k,v in ipairs(I)do
	if autorefresh[v]then continue end
	if v:StartWith"cl_"and CLIENT--clientside only
	or v:StartWith"sv_"and SERVER--serverside only
	or v:StartWith"sh_"then--shared
		MsgN("ppm/custom_scripts/",v)
		include("ppm/custom_scripts/"..v)
	end
end
if file.Exists("ppm/pony_hoofstep_sounds.lua","LUA") then
	include("ppm/pony_hoofstep_sounds.lua")
end
if CLIENT and file.Exists("ppm/extension.lua","LUA") then
	include("ppm/extension.lua")
end
if CPPM and CPPM.Inject then--reload CPPM's stuff
	local ConVar=GetConVar"cppm_active"
	if ConVar and ConVar:GetBool() then
		CPPM:Inject()
	end
end
