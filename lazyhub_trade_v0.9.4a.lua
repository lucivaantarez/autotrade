--[[ LazyHub bootstrap ]]
local __ok, __err = pcall(function()
--[[
    LazyHub | v0.9.0a
    "for lazy people who want to be even lazier"

    RELEASER  - bulk pet recycle, auto-enter nursery, auto-claim tickets
    TRADE     - pick items from full inventory, drop into open trade box
    AUTO      - automated trading: select player, select items, auto-accept,
                auto-confirm, re-fire on decline, trade counter, full log
    HISTORY   - visual trade history grid (3 per row)
    PLAYERS   - server player list with teleport + trade
    SETTINGS  - opacity, rejoin, about
]]

local Players = game:GetService("Players")
local RS      = game:GetService("ReplicatedStorage")
local UIS     = game:GetService("UserInputService")
local TS      = game:GetService("TweenService")
local CS      = game:GetService("CollectionService")
local TPS     = game:GetService("TeleportService")
local LP      = Players.LocalPlayer

local Fsys        = require(RS:WaitForChild("Fsys")).load
local ClientData  = Fsys("ClientData")
local InventoryDB = Fsys("InventoryDB")
local InteriorsM  = Fsys("InteriorsM")
local Router      = Fsys("RouterClient")
local UIManager   = Fsys("UIManager")

local VERSION   = "0.9.4a"
local TICKET_ID = "pet_recycler_tickets_2026"
local LOGO_URL  = "https://raw.githubusercontent.com/lucivaantarez/farm/main/lazyhub-logo.png"

-- lazy modules
local KindDB, Promise, DialogApp
local function ensure_kinddb()
    if KindDB then return true end
    local ok, db = pcall(function() return Fsys("KindDB") end)
    if ok and db then KindDB = db return true end
    return false
end
local function ensure_promise()
    if Promise then return true end
    local ok, p = pcall(function() return Fsys("package:Promise") end)
    if ok and p then Promise = p return true end
    return false
end
local function get_dialog_app()
    if DialogApp then return DialogApp end
    local ok = pcall(function() DialogApp = UIManager.apps.DialogApp end)
    return DialogApp
end

--=========================================================
-- THEME
--=========================================================
local C = {
    bg=Color3.fromRGB(0,0,0), rail=Color3.fromRGB(8,8,10),
    panel=Color3.fromRGB(13,13,16), card=Color3.fromRGB(17,17,21),
    cell=Color3.fromRGB(21,21,26), cellOn=Color3.fromRGB(32,26,55),
    chip=Color3.fromRGB(24,24,29),
    purple=Color3.fromRGB(167,119,255), cyan=Color3.fromRGB(78,231,255),
    red=Color3.fromRGB(255,82,104), green=Color3.fromRGB(86,226,150),
    amber=Color3.fromRGB(255,196,74), text=Color3.fromRGB(240,242,250),
    dim=Color3.fromRGB(150,155,175), muted=Color3.fromRGB(96,100,120),
}
local F_TITLE=Enum.Font.GothamBlack
local F_BOLD=Enum.Font.GothamBold
local F_BODY=Enum.Font.Gotham
local F_LOG=Enum.Font.Code

local RARITIES={"common","uncommon","rare","ultra_rare","legendary"}
local TYPES={"NP","R","F","FR","N","NR","NFR","M","MR","MFR"}
local RISKY={legendary=true,ultra_rare=true}
local RCOL={common=Color3.fromRGB(150,155,172),uncommon=Color3.fromRGB(120,220,140),
    rare=Color3.fromRGB(96,165,250),ultra_rare=Color3.fromRGB(192,132,252),
    legendary=Color3.fromRGB(255,196,74)}

local function nice(r) if r=="ultra_rare" then return "Ultra-Rare" end return (tostring(r or "?"):gsub("^%l",string.upper)) end
local function comma(n) local s=tostring(math.floor(n or 0)) local k repeat s,k=s:gsub("^(-?%d+)(%d%d%d)","%1,%2") until k==0 return s end
local function clock() return os.date("%H:%M:%S") end
local function get_tickets() local ok,v=pcall(function() return ClientData.get(TICKET_ID) end) if ok and type(v)=="number" then return v end return nil end

local LOGO_IMAGE=nil
pcall(function()
    if LOGO_URL~="" then
        local data=game:HttpGet(LOGO_URL) writefile("lazyhub_logo.png",data)
        LOGO_IMAGE=getcustomasset("lazyhub_logo.png")
    end
end)

local function kind_lookup(id)
    if not id then return nil end
    if ensure_kinddb() then
        local ok,def=pcall(function() return KindDB[id] end)
        if ok and type(def)=="table" then return def end
    end
    return nil
end

--=========================================================
-- INVENTORY
--=========================================================
local ALL_CATS={
    {key="pets",label="PETS"},{key="food",label="FOOD"},{key="toys",label="TOYS"},
    {key="gifts",label="GIFTS"},{key="strollers",label="STROLLERS"},
    {key="transport",label="VEHICLES"},{key="pet_accessories",label="PET WEAR"},
    {key="stickers",label="STICKERS"},{key="roleplay",label="ROLEPLAY"},
}

local function build_stacks(catFilter)
    local stacks={}
    local inv=ClientData.get("inventory")
    if not inv then return stacks,{} end
    local cats=ALL_CATS
    if catFilter then
        cats={}
        for _,c in ipairs(ALL_CATS) do if catFilter[c.key] then table.insert(cats,c) end end
        if #cats==0 then cats=ALL_CATS end
    end
    for _,catInfo in ipairs(cats) do
        local cat=catInfo.key
        local items=inv[cat]
        if type(items)~="table" then items={} end
        for unique,item in pairs(items) do
            pcall(function()
                if type(item)~="table" then return end
                local id=item.id if not id then return end
                local name,image,rarity,is_egg=tostring(id),"","item",false
                if cat=="pets" then
                    local ok2,def=pcall(function() return InventoryDB.pets[id] end)
                    if ok2 and type(def)=="table" then
                        name=def.name or name image=def.image or "" rarity=tostring(def.rarity or "?"):lower() is_egg=def.is_egg
                    end
                else
                    local def=kind_lookup(id)
                    if def then name=def.name or name image=def.image or "" end
                end
                if is_egg then return end
                local tag=""
                if cat=="pets" then
                    local p=item.properties or {}
                    if p.mega_neon then tag="M" elseif p.neon then tag="N" end
                    if p.flyable then tag=tag.."F" end if p.rideable then tag=tag.."R" end
                    if tag=="" then tag="NP" end
                else tag=catInfo.label:sub(1,4) end
                local key=cat.."|"..tostring(id).."|"..tag
                local st=stacks[key]
                if not st then
                    local risky=false
                    if cat=="pets" then local p=item.properties or {} risky=(p.neon or p.mega_neon or RISKY[rarity]) and true or false end
                    st={key=key,id=id,name=name,image=image,rarity=rarity,tag=tag,category=cat,risky=risky,uniques={}}
                    stacks[key]=st
                end
                table.insert(st.uniques,unique)
            end)
        end
    end
    local arr={}
    for _,st in pairs(stacks) do table.insert(arr,st) end
    table.sort(arr,function(a,b)
        local ac=a.category or "pets" local bc=b.category or "pets"
        if ac~=bc then return ac<bc end
        if a.name==b.name then return a.tag<b.tag end return a.name<b.name
    end)
    return stacks,arr
end

--=========================================================
-- GUI SHELL
--=========================================================
local gui=Instance.new("ScreenGui") gui.Name="LazyHub" gui.ResetOnSpawn=false
gui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling
gui.Parent=(gethui and gethui()) or LP:WaitForChild("PlayerGui")

local function corner(o,r) local c=Instance.new("UICorner") c.CornerRadius=UDim.new(0,r or 8) c.Parent=o end
local FADE={} local function tracked(o) table.insert(FADE,o) return o end
local MINW,MINH=560,520 local RAIL=128

local root=Instance.new("Frame") root.Size=UDim2.fromOffset(680,680)
root.Position=UDim2.new(0.5,-340,0.5,-340) root.BackgroundColor3=C.bg
root.BorderSizePixel=0 root.Active=true root.ClipsDescendants=true root.Parent=gui
corner(root,16) tracked(root)

-- header
local header=Instance.new("Frame") header.Size=UDim2.new(1,0,0,52) header.BackgroundColor3=C.panel
header.BorderSizePixel=0 header.Active=true header.Parent=root corner(header,16) tracked(header)
local hfix=Instance.new("Frame") hfix.Size=UDim2.new(1,0,0,16) hfix.Position=UDim2.new(0,0,1,-16)
hfix.BackgroundColor3=C.panel hfix.BorderSizePixel=0 hfix.Parent=header tracked(hfix)

local logo=Instance.new("ImageLabel") logo.Size=UDim2.fromOffset(30,30) logo.Position=UDim2.fromOffset(14,11)
logo.BackgroundColor3=LOGO_IMAGE and C.panel or C.purple logo.BorderSizePixel=0
logo.Image=LOGO_IMAGE or "" logo.ScaleType=Enum.ScaleType.Fit logo.Parent=header corner(logo,9)
if not LOGO_IMAGE then local l=Instance.new("TextLabel") l.Size=UDim2.fromScale(1,1) l.BackgroundTransparency=1
l.Font=F_TITLE l.Text="L" l.TextColor3=Color3.new(1,1,1) l.TextSize=18 l.Parent=logo end

local brand=Instance.new("TextLabel") brand.Size=UDim2.fromOffset(150,22) brand.Position=UDim2.fromOffset(52,8)
brand.BackgroundTransparency=1 brand.Font=F_TITLE brand.Text="LazyHub" brand.TextColor3=C.text
brand.TextSize=20 brand.TextXAlignment=Enum.TextXAlignment.Left brand.Parent=header
local ver=Instance.new("TextLabel") ver.Size=UDim2.fromOffset(150,13) ver.Position=UDim2.fromOffset(53,29)
ver.BackgroundTransparency=1 ver.Font=F_BODY ver.Text="v"..VERSION ver.TextColor3=C.purple
ver.TextSize=11 ver.TextXAlignment=Enum.TextXAlignment.Left ver.Parent=header

local tik=Instance.new("Frame") tik.Size=UDim2.fromOffset(146,34) tik.Position=UDim2.new(1,-230,0,9)
tik.BackgroundColor3=C.cell tik.BorderSizePixel=0 tik.Parent=header corner(tik,9) tracked(tik)
local tikDot=Instance.new("Frame") tikDot.Size=UDim2.fromOffset(3,20) tikDot.Position=UDim2.fromOffset(9,7)
tikDot.BackgroundColor3=C.amber tikDot.BorderSizePixel=0 tikDot.Parent=tik corner(tikDot,2)
local tikCap=Instance.new("TextLabel") tikCap.Size=UDim2.fromOffset(116,11) tikCap.Position=UDim2.fromOffset(19,5)
tikCap.BackgroundTransparency=1 tikCap.Font=F_BODY tikCap.Text="RECYCLING TICKETS"
tikCap.TextColor3=C.muted tikCap.TextSize=9 tikCap.TextXAlignment=Enum.TextXAlignment.Left tikCap.Parent=tik
local tikVal=Instance.new("TextLabel") tikVal.Size=UDim2.fromOffset(120,17) tikVal.Position=UDim2.fromOffset(19,15)
tikVal.BackgroundTransparency=1 tikVal.Font=F_TITLE tikVal.Text="--" tikVal.TextColor3=C.amber
tikVal.TextSize=14 tikVal.TextXAlignment=Enum.TextXAlignment.Left tikVal.Parent=tik

local function hbtn(x,txt,col) local b=Instance.new("TextButton") b.Size=UDim2.fromOffset(30,30)
b.Position=UDim2.new(1,x,0,11) b.BackgroundColor3=C.cell b.BorderSizePixel=0 b.Font=F_BOLD
b.Text=txt b.TextColor3=col b.TextSize=15 b.Parent=header corner(b,9) tracked(b) return b end
local closeBtn=hbtn(-42,"X",C.red) local minBtn=hbtn(-78,"-",C.amber)

-- shell + rail
local shell=Instance.new("Frame") shell.Size=UDim2.new(1,0,1,-52) shell.Position=UDim2.fromOffset(0,52)
shell.BackgroundTransparency=1 shell.Parent=root
local rail=Instance.new("Frame") rail.Size=UDim2.new(0,RAIL,1,0) rail.BackgroundColor3=C.rail
rail.BorderSizePixel=0 rail.Parent=shell tracked(rail) corner(rail,14)
local railLay=Instance.new("UIListLayout") railLay.Padding=UDim.new(0,5) railLay.SortOrder=Enum.SortOrder.LayoutOrder railLay.Parent=rail
local railPad=Instance.new("UIPadding") railPad.PaddingTop=UDim.new(0,12) railPad.PaddingLeft=UDim.new(0,8) railPad.PaddingRight=UDim.new(0,8) railPad.Parent=rail

local pages,navs={},{}
local function show(name) for n,p in pairs(pages) do p.Visible=(n==name) end
for n,b in pairs(navs) do local on=(n==name) b.BackgroundColor3=on and C.cellOn or C.rail
local ic,tx=b:FindFirstChild("ic"),b:FindFirstChild("tx")
if ic then ic.ImageColor3=on and C.cyan or C.muted end
local fb=b:FindFirstChild("fb") if fb then fb.TextColor3=on and C.cyan or C.muted end
if tx then tx.TextColor3=on and C.text or C.muted end end end

local navN=0
local function page(name,label,iconId) navN=navN+1
local b=Instance.new("TextButton") b.Size=UDim2.new(1,0,0,36) b.BackgroundColor3=C.rail
b.BorderSizePixel=0 b.Text="" b.LayoutOrder=navN b.Parent=rail corner(b,9)
local ic=Instance.new("ImageLabel") ic.Name="ic" ic.Size=UDim2.fromOffset(18,18) ic.Position=UDim2.fromOffset(10,9)
ic.BackgroundTransparency=1 ic.Image=iconId ic.ImageColor3=C.muted ic.ScaleType=Enum.ScaleType.Fit ic.Parent=b
    local fb=Instance.new("TextLabel") fb.Name="fb" fb.Size=UDim2.fromOffset(18,18) fb.Position=UDim2.fromOffset(10,9)
    fb.BackgroundTransparency=1 fb.Font=F_BOLD fb.Text=label:sub(1,1) fb.TextColor3=C.muted fb.TextSize=14
    fb.Parent=b fb.Visible=true
    task.spawn(function() task.wait(1) if ic.IsLoaded then fb.Visible=false end end)
local tx=Instance.new("TextLabel") tx.Name="tx" tx.Size=UDim2.new(1,-36,1,0) tx.Position=UDim2.fromOffset(35,0)
tx.BackgroundTransparency=1 tx.Font=F_BOLD tx.Text=label tx.TextColor3=C.muted tx.TextSize=12
tx.TextXAlignment=Enum.TextXAlignment.Left tx.Parent=b
b.MouseButton1Click:Connect(function() show(name) end) navs[name]=b
local p=Instance.new("Frame") p.Name=name p.Size=UDim2.new(1,-RAIL,1,0) p.Position=UDim2.fromOffset(RAIL,0)
p.BackgroundTransparency=1 p.Visible=false p.Parent=shell pages[name]=p return p end

local pRel  =page("releaser","RELEASER","rbxassetid://6031225819")   -- paw
local pTrade=page("trade","TRADE","rbxassetid://6034684949")          -- swap arrows
local pAuto =page("auto","AUTO TRADE","rbxassetid://6034509993")      -- bot/repeat
local pHist =page("history","HISTORY","rbxassetid://6022668888")      -- clock
local pPlay =page("players","PLAYERS","rbxassetid://6031225819")      -- people
local pSet  =page("settings","SETTINGS","rbxassetid://6031280882")    -- gear


--=========================================================
-- SHARED: log console factory
--=========================================================
local function make_log(parent,y,h)
    local head=Instance.new("TextLabel") head.Size=UDim2.new(1,-24,0,14) head.Position=UDim2.new(0,12,1,y)
    head.BackgroundTransparency=1 head.Font=F_BODY head.Text="ACTIVITY" head.TextColor3=C.muted
    head.TextSize=9 head.TextXAlignment=Enum.TextXAlignment.Left head.Parent=parent
    local box=Instance.new("ScrollingFrame") box.Size=UDim2.new(1,-24,0,h) box.Position=UDim2.new(0,12,1,y+16)
    box.BackgroundColor3=C.panel box.BorderSizePixel=0 box.ScrollBarThickness=3
    box.ScrollBarImageColor3=C.muted box.CanvasSize=UDim2.new() box.Parent=parent corner(box,10) tracked(box)
    local lay=Instance.new("UIListLayout") lay.Padding=UDim.new(0,3) lay.SortOrder=Enum.SortOrder.LayoutOrder lay.Parent=box
    local pad=Instance.new("UIPadding") pad.PaddingTop=UDim.new(0,7) pad.PaddingLeft=UDim.new(0,9)
    pad.PaddingRight=UDim.new(0,9) pad.Parent=box
    local n,rows=0,{}
    local function log(msg,col) n=n+1
        local row=Instance.new("Frame") row.Size=UDim2.new(1,0,0,15) row.BackgroundTransparency=1 row.LayoutOrder=n row.Parent=box
        local t=Instance.new("TextLabel") t.Size=UDim2.fromOffset(58,15) t.BackgroundTransparency=1 t.Font=F_LOG t.Text=clock()
        t.TextColor3=C.muted t.TextSize=11 t.TextXAlignment=Enum.TextXAlignment.Left t.Parent=row
        local m=Instance.new("TextLabel") m.Size=UDim2.new(1,-62,1,0) m.Position=UDim2.fromOffset(62,0) m.BackgroundTransparency=1
        m.Font=F_LOG m.Text=msg m.TextColor3=col or C.dim m.TextSize=12 m.TextXAlignment=Enum.TextXAlignment.Left
        m.TextTruncate=Enum.TextTruncate.AtEnd m.Parent=row
        table.insert(rows,row) while #rows>200 do rows[1]:Destroy() table.remove(rows,1) end
        task.defer(function() box.CanvasSize=UDim2.fromOffset(0,lay.AbsoluteContentSize.Y+14)
        box.CanvasPosition=Vector2.new(0,math.max(0,box.CanvasSize.Y.Offset-box.AbsoluteSize.Y)) end)
    end
    return log
end

--=========================================================
-- SHARED: pet grid widget
--=========================================================
local function make_grid(parent,top,bottom,on_log,showCatBar,defaultCat)
    local ALL,STACKS={},{}
    local picked={} local search,fRar,fTyp,protect="",{},{},true
    local activeCat={} local rendering=false

    local function reload()
        local cf=defaultCat if next(activeCat) then cf=activeCat end STACKS,ALL=build_stacks(cf)
    end
    reload()

    if showCatBar then
        local catBar=Instance.new("ScrollingFrame") catBar.Size=UDim2.new(1,-24,0,32)
        catBar.Position=UDim2.fromOffset(12,top) catBar.BackgroundTransparency=1 catBar.BorderSizePixel=0
        catBar.ScrollBarThickness=0 catBar.ScrollingDirection=Enum.ScrollingDirection.X
        catBar.CanvasSize=UDim2.new() catBar.Parent=parent
        local cbLay=Instance.new("UIListLayout") cbLay.FillDirection=Enum.FillDirection.Horizontal
        cbLay.Padding=UDim.new(0,5) cbLay.SortOrder=Enum.SortOrder.LayoutOrder cbLay.Parent=catBar
        for ci,catInfo in ipairs(ALL_CATS) do
            local cb=Instance.new("TextButton") cb.Size=UDim2.fromOffset(#catInfo.label*7+16,28)
            cb.BackgroundColor3=C.chip cb.BorderSizePixel=0 cb.Font=F_BOLD cb.Text=catInfo.label
            cb.TextColor3=C.muted cb.TextSize=10 cb.LayoutOrder=ci cb.Parent=catBar corner(cb,8)
            cb.MouseButton1Click:Connect(function()
                if activeCat[catInfo.key] then activeCat[catInfo.key]=nil cb.BackgroundColor3=C.chip cb.TextColor3=C.muted
                else activeCat[catInfo.key]=true cb.BackgroundColor3=C.purple cb.TextColor3=Color3.new(1,1,1) end
                reload() if render then render() end on_log("Filter: "..#ALL.." stacks.",C.cyan)
            end)
        end
        catBar.CanvasSize=UDim2.fromOffset(cbLay.AbsoluteContentSize.X+10,0) top=top+38
    end

    local function any(t) return next(t)~=nil end
    local function visible()
        local out={}
        for _,s in ipairs(ALL) do
            local ok=true
            if search~="" and not s.name:lower():find(search:lower(),1,true) then ok=false end
            if any(fRar) and not fRar[s.rarity] then ok=false end
            if any(fTyp) and not fTyp[s.tag] then ok=false end
            if protect and s.risky then ok=false end
            if ok then table.insert(out,s) end
        end return out
    end

    local searchBox=Instance.new("TextBox") searchBox.Size=UDim2.new(1,-212,0,34)
    searchBox.Position=UDim2.fromOffset(12,top) searchBox.BackgroundColor3=C.panel searchBox.BorderSizePixel=0
    searchBox.Font=F_BODY searchBox.PlaceholderText="Search by name" searchBox.Text=""
    searchBox.TextColor3=C.text searchBox.PlaceholderColor3=C.muted searchBox.TextSize=13
    searchBox.ClearTextOnFocus=false searchBox.Parent=parent corner(searchBox,9) tracked(searchBox)

    local function tbtn(xOff,w,txt,col) local b=Instance.new("TextButton") b.Size=UDim2.fromOffset(w,34)
    b.Position=UDim2.new(1,xOff,0,top) b.BackgroundColor3=C.panel b.BorderSizePixel=0
    b.Font=F_BOLD b.Text=txt b.TextColor3=col b.TextSize=11 b.Parent=parent corner(b,9) tracked(b) return b end
    local filtBtn=tbtn(-192,88,"FILTERS",C.dim) local refBtn=tbtn(-98,86,"REFRESH",C.cyan)

    local drawer=Instance.new("Frame") drawer.Size=UDim2.new(1,-24,0,80) drawer.Position=UDim2.fromOffset(12,top+42)
    drawer.BackgroundColor3=C.panel drawer.BorderSizePixel=0 drawer.Visible=false drawer.Parent=parent corner(drawer,10) tracked(drawer)
    local dPad=Instance.new("UIPadding") dPad.PaddingTop=UDim.new(0,6) dPad.PaddingLeft=UDim.new(0,8) dPad.PaddingRight=UDim.new(0,8) dPad.Parent=drawer
    local dLay=Instance.new("UIListLayout") dLay.Padding=UDim.new(0,4) dLay.SortOrder=Enum.SortOrder.LayoutOrder dLay.Parent=drawer
    local function chipLabel(txt,o) local l=Instance.new("TextLabel") l.Size=UDim2.new(1,0,0,11)
    l.BackgroundTransparency=1 l.Font=F_BODY l.Text=txt l.TextColor3=C.muted l.TextSize=8
    l.TextXAlignment=Enum.TextXAlignment.Left l.LayoutOrder=o l.Parent=drawer end
    local function chipRow(o) local f=Instance.new("Frame") f.Size=UDim2.new(1,0,0,22) f.BackgroundTransparency=1
    f.LayoutOrder=o f.Parent=drawer local l=Instance.new("UIListLayout") l.FillDirection=Enum.FillDirection.Horizontal
    l.Padding=UDim.new(0,4) l.SortOrder=Enum.SortOrder.LayoutOrder l.Parent=f return f end
    chipLabel("RARITY",1) local rowR=chipRow(2) chipLabel("TYPE",3) local rowT=chipRow(4)
    local cn=0
    local function chip(par,label,col,set,key) cn=cn+1 local b=Instance.new("TextButton")
    b.Size=UDim2.fromOffset(#label*7+16,20) b.BackgroundColor3=C.chip b.BorderSizePixel=0 b.Font=F_BOLD
    b.Text=label b.TextColor3=C.muted b.TextSize=9 b.LayoutOrder=cn b.Parent=par corner(b,10)
    b.MouseButton1Click:Connect(function()
        if set[key] then set[key]=nil b.BackgroundColor3=C.chip b.TextColor3=C.muted
        else set[key]=true b.BackgroundColor3=col b.TextColor3=C.bg end
        if render then render() end
    end) end
    for _,r in ipairs(RARITIES) do chip(rowR,nice(r):upper(),RCOL[r],fRar,r) end
    for _,t in ipairs(TYPES) do chip(rowT,t,C.cyan,fTyp,t) end

    local protBtn=Instance.new("TextButton") protBtn.Size=UDim2.new(0,148,0,26)
    protBtn.Position=UDim2.fromOffset(12,top+42) protBtn.BackgroundColor3=C.panel protBtn.BorderSizePixel=0
    protBtn.Font=F_BOLD protBtn.Text="RARES PROTECTED" protBtn.TextColor3=C.green protBtn.TextSize=10
    protBtn.Parent=parent corner(protBtn,8) tracked(protBtn)
    local clrBtn=Instance.new("TextButton") clrBtn.Size=UDim2.new(0,100,0,26)
    clrBtn.Position=UDim2.fromOffset(166,top+42) clrBtn.BackgroundColor3=C.panel clrBtn.BorderSizePixel=0
    clrBtn.Font=F_BOLD clrBtn.Text="CLEAR PICKS" clrBtn.TextColor3=C.muted clrBtn.TextSize=10
    clrBtn.Parent=parent corner(clrBtn,8) tracked(clrBtn)

    local gridTop=top+42+34
    local grid=Instance.new("ScrollingFrame") grid.Position=UDim2.fromOffset(12,gridTop)
    grid.Size=UDim2.new(1,-24,1,-(gridTop+bottom)) grid.BackgroundColor3=C.panel grid.BorderSizePixel=0
    grid.ScrollBarThickness=4 grid.ScrollBarImageColor3=C.purple grid.CanvasSize=UDim2.new()
    grid.Parent=parent corner(grid,11) tracked(grid)
    local gl=Instance.new("UIGridLayout") gl.CellSize=UDim2.fromOffset(78,94) gl.CellPadding=UDim2.fromOffset(7,7)
    gl.SortOrder=Enum.SortOrder.LayoutOrder gl.Parent=grid
    local gPad=Instance.new("UIPadding") gPad.PaddingTop=UDim.new(0,9) gPad.PaddingLeft=UDim.new(0,9)
    gPad.PaddingBottom=UDim.new(0,9) gPad.Parent=grid

    -- qty picker
    local ov=Instance.new("TextButton") ov.Size=UDim2.fromScale(1,1) ov.BackgroundColor3=Color3.new(0,0,0)
    ov.BackgroundTransparency=0.45 ov.Text="" ov.Visible=false ov.ZIndex=30 ov.AutoButtonColor=false
    ov.Parent=root corner(ov,16)
    local qb=Instance.new("Frame") qb.Size=UDim2.fromOffset(268,196) qb.Position=UDim2.new(0.5,-134,0.5,-98)
    qb.BackgroundColor3=C.panel qb.BorderSizePixel=0 qb.ZIndex=31 qb.Parent=ov corner(qb,13)
    local qIcon=Instance.new("ImageLabel") qIcon.Size=UDim2.fromOffset(46,46) qIcon.Position=UDim2.fromOffset(14,14)
    qIcon.BackgroundColor3=C.cell qIcon.BorderSizePixel=0 qIcon.ScaleType=Enum.ScaleType.Fit qIcon.ZIndex=32 qIcon.Parent=qb corner(qIcon,9)
    local qName=Instance.new("TextLabel") qName.Size=UDim2.fromOffset(190,20) qName.Position=UDim2.fromOffset(70,16)
    qName.BackgroundTransparency=1 qName.Font=F_BOLD qName.TextSize=14 qName.TextColor3=C.text
    qName.TextXAlignment=Enum.TextXAlignment.Left qName.TextTruncate=Enum.TextTruncate.AtEnd qName.ZIndex=32 qName.Parent=qb
    local qSub=Instance.new("TextLabel") qSub.Size=UDim2.fromOffset(190,16) qSub.Position=UDim2.fromOffset(70,37)
    qSub.BackgroundTransparency=1 qSub.Font=F_BODY qSub.TextSize=11 qSub.TextColor3=C.muted
    qSub.TextXAlignment=Enum.TextXAlignment.Left qSub.ZIndex=32 qSub.Parent=qb
    local qVal=Instance.new("TextBox") qVal.Size=UDim2.fromOffset(94,42) qVal.Position=UDim2.fromOffset(87,76)
    qVal.BackgroundColor3=C.cell qVal.BorderSizePixel=0 qVal.Font=F_TITLE qVal.TextSize=20
    qVal.TextColor3=C.text qVal.Text="1" qVal.ClearTextOnFocus=false qVal.ZIndex=32 qVal.Parent=qb corner(qVal,9)
    local function qbtn(x,txt) local b=Instance.new("TextButton") b.Size=UDim2.fromOffset(62,42)
    b.Position=UDim2.fromOffset(x,76) b.BackgroundColor3=C.cell b.BorderSizePixel=0 b.Font=F_TITLE b.Text=txt
    b.TextColor3=C.cyan b.TextSize=18 b.ZIndex=32 b.Parent=qb corner(b,9) return b end
    local qMinus,qPlus=qbtn(14,"-"),qbtn(192,"+")
    local qRem=Instance.new("TextButton") qRem.Size=UDim2.fromOffset(78,36) qRem.Position=UDim2.fromOffset(14,132)
    qRem.BackgroundColor3=C.cell qRem.BorderSizePixel=0 qRem.Font=F_BOLD qRem.Text="REMOVE"
    qRem.TextColor3=C.red qRem.TextSize=11 qRem.ZIndex=32 qRem.Parent=qb corner(qRem,9)
    local qMax=Instance.new("TextButton") qMax.Size=UDim2.fromOffset(78,36) qMax.Position=UDim2.fromOffset(96,132)
    qMax.BackgroundColor3=C.cell qMax.BorderSizePixel=0 qMax.Font=F_BOLD qMax.Text="ALL"
    qMax.TextColor3=C.amber qMax.TextSize=11 qMax.ZIndex=32 qMax.Parent=qb corner(qMax,9)
    local qAdd=Instance.new("TextButton") qAdd.Size=UDim2.fromOffset(92,36) qAdd.Position=UDim2.fromOffset(178,132)
    qAdd.BackgroundColor3=C.purple qAdd.BorderSizePixel=0 qAdd.Font=F_TITLE qAdd.Text="ADD"
    qAdd.TextColor3=Color3.new(1,1,1) qAdd.TextSize=12 qAdd.ZIndex=32 qAdd.Parent=qb corner(qAdd,9)

    local qCur
    local function clampQ(n) if not qCur then return 1 end return math.clamp(math.floor(tonumber(n) or 1),0,#qCur.uniques) end
    local function setQ(n) qVal.Text=tostring(clampQ(n)) end
    local function openQty(s) qCur=s qIcon.Image=s.image qName.Text=s.name
    qSub.Text=s.tag.."  .  "..nice(s.rarity).."  .  own "..#s.uniques
    setQ(picked[s.key] or #s.uniques) ov.Visible=true end
    qMinus.MouseButton1Click:Connect(function() setQ((tonumber(qVal.Text) or 1)-1) end)
    qPlus.MouseButton1Click:Connect(function() setQ((tonumber(qVal.Text) or 0)+1) end)
    qMax.MouseButton1Click:Connect(function() setQ(qCur and #qCur.uniques or 1) end)
    qVal.FocusLost:Connect(function() setQ(qVal.Text) end)
    ov.MouseButton1Click:Connect(function() ov.Visible=false end)
    qRem.MouseButton1Click:Connect(function()
        if qCur then picked[qCur.key]=nil on_log("Removed "..qCur.name,C.muted) end
        ov.Visible=false if render then render() end end)
    qAdd.MouseButton1Click:Connect(function()
        if not qCur then return end local n=clampQ(qVal.Text)
        if n<=0 then picked[qCur.key]=nil on_log("Removed "..qCur.name,C.muted)
        else picked[qCur.key]=n on_log("Picked "..n.."x "..qCur.name,C.cyan) end
        ov.Visible=false if render then render() end end)

    local render
    local cells={}
    function render()
        if rendering then return end rendering=true
        for _,c in ipairs(cells) do c:Destroy() end cells={}
        local vis=visible()
        for i,s in ipairs(vis) do
            local n=picked[s.key] or 0
            local cell=Instance.new("TextButton") cell.BackgroundColor3=n>0 and C.cellOn or C.cell
            cell.BorderSizePixel=0 cell.Text="" cell.LayoutOrder=i cell.AutoButtonColor=false cell.Parent=grid corner(cell,10)
            local strip=Instance.new("Frame") strip.Size=UDim2.new(1,-18,0,3) strip.Position=UDim2.fromOffset(9,6)
            strip.BackgroundColor3=RCOL[s.rarity] or C.muted strip.BorderSizePixel=0 strip.Parent=cell corner(strip,2)
            local img=Instance.new("ImageLabel") img.Size=UDim2.fromOffset(44,44) img.Position=UDim2.new(0.5,-22,0,14)
            img.BackgroundTransparency=1 img.Image=s.image img.ScaleType=Enum.ScaleType.Fit img.Parent=cell
            local nm=Instance.new("TextLabel") nm.Size=UDim2.new(1,-8,0,13) nm.Position=UDim2.fromOffset(4,60)
            nm.BackgroundTransparency=1 nm.Font=F_BOLD nm.TextSize=10 nm.TextColor3=s.risky and C.red or C.text
            nm.TextTruncate=Enum.TextTruncate.AtEnd nm.Text=s.name nm.Parent=cell
            local meta=Instance.new("TextLabel") meta.Size=UDim2.new(1,-8,0,12) meta.Position=UDim2.fromOffset(4,73)
            meta.BackgroundTransparency=1 meta.Font=F_BODY meta.TextSize=9 meta.TextColor3=C.muted
            meta.Text=s.tag.."  x"..#s.uniques meta.Parent=cell
            if n>0 then
                local edge=Instance.new("Frame") edge.Size=UDim2.new(0,3,1,-12) edge.Position=UDim2.fromOffset(0,6)
                edge.BackgroundColor3=C.cyan edge.BorderSizePixel=0 edge.Parent=cell corner(edge,2)
                local badge=Instance.new("TextLabel") badge.Size=UDim2.fromOffset(28,17)
                badge.Position=UDim2.new(1,-32,0,13) badge.BackgroundColor3=C.purple badge.BorderSizePixel=0
                badge.Font=F_BOLD badge.TextSize=10 badge.TextColor3=Color3.new(1,1,1) badge.Text=tostring(n)
                badge.Parent=cell corner(badge,8)
            end
            cell.MouseButton1Click:Connect(function() openQty(s) end)
            table.insert(cells,cell)
        end
        grid.CanvasSize=UDim2.fromOffset(0,gl.AbsoluteContentSize.Y+18) rendering=false
    end

    searchBox:GetPropertyChangedSignal("Text"):Connect(function() search=searchBox.Text render() end)
    filtBtn.MouseButton1Click:Connect(function()
        local open=not drawer.Visible drawer.Visible=open
        filtBtn.Text=open and "HIDE" or "FILTERS" filtBtn.TextColor3=open and C.cyan or C.dim
        protBtn.Visible=not open clrBtn.Visible=not open
        local gt=open and (top+42+88) or gridTop
        grid.Position=UDim2.fromOffset(12,gt) grid.Size=UDim2.new(1,-24,1,-(gt+bottom))
        task.defer(render) end)
    protBtn.MouseButton1Click:Connect(function()
        protect=not protect protBtn.Text=protect and "RARES PROTECTED" or "RARES UNLOCKED"
        protBtn.TextColor3=protect and C.green or C.red
        if protect then for _,s in ipairs(ALL) do if s.risky then picked[s.key]=nil end end end render() end)
    clrBtn.MouseButton1Click:Connect(function() picked={} on_log("Picks cleared",C.muted) render() end)
    refBtn.MouseButton1Click:Connect(function() reload() picked={} render() on_log("Reloaded. "..#ALL.." stacks.",C.cyan) end)
    render()
    return {render=render,stacks=function() return STACKS end,picked=function() return picked end,
        clear=function() picked={} render() end,refresh=function() reload() render() end}
end


--=========================================================
-- RELEASER PAGE
--=========================================================
local relLog=make_log(pRel,-164,100)
local relGrid=make_grid(pRel,12,210,relLog,false,{pets=true})
local fire=Instance.new("TextButton") fire.Size=UDim2.new(1,-24,0,36) fire.Position=UDim2.new(0,12,1,-44)
fire.BackgroundColor3=C.purple fire.BorderSizePixel=0 fire.Font=F_TITLE fire.Text="RELEASE"
fire.TextColor3=Color3.new(1,1,1) fire.TextSize=14 fire.Parent=pRel corner(fire,10)

--=========================================================
-- TRADE PAGE
--=========================================================
local trLog=make_log(pTrade,-164,100)
local trGrid=make_grid(pTrade,12,210,trLog,true,nil)
local trFire=Instance.new("TextButton") trFire.Size=UDim2.new(1,-24,0,36) trFire.Position=UDim2.new(0,12,1,-44)
trFire.BackgroundColor3=C.cyan trFire.BorderSizePixel=0 trFire.Font=F_TITLE trFire.Text="PUT ITEMS IN TRADE"
trFire.TextColor3=C.bg trFire.TextSize=14 trFire.Parent=pTrade corner(trFire,10)

--=========================================================
-- AUTO TRADE PAGE
--=========================================================
local atLog=make_log(pAuto,-164,100)

local atStatus=Instance.new("TextLabel") atStatus.Size=UDim2.new(1,-24,0,18) atStatus.Position=UDim2.fromOffset(12,12)
atStatus.BackgroundTransparency=1 atStatus.Font=F_BOLD atStatus.Text="AUTO TRADE - IDLE"
atStatus.TextColor3=C.muted atStatus.TextSize=13 atStatus.TextXAlignment=Enum.TextXAlignment.Left atStatus.Parent=pAuto

local atCount=Instance.new("TextLabel") atCount.Size=UDim2.fromOffset(120,18) atCount.Position=UDim2.new(1,-132,0,12)
atCount.BackgroundTransparency=1 atCount.Font=F_TITLE atCount.Text="0 trades" atCount.TextColor3=C.green
atCount.TextSize=13 atCount.TextXAlignment=Enum.TextXAlignment.Right atCount.Parent=pAuto

-- target player selector
local atTargetLbl=Instance.new("TextLabel") atTargetLbl.Size=UDim2.new(1,-24,0,12) atTargetLbl.Position=UDim2.fromOffset(12,38)
atTargetLbl.BackgroundTransparency=1 atTargetLbl.Font=F_BODY atTargetLbl.Text="TARGET PLAYER"
atTargetLbl.TextColor3=C.muted atTargetLbl.TextSize=9 atTargetLbl.TextXAlignment=Enum.TextXAlignment.Left atTargetLbl.Parent=pAuto

local atTargetScroll=Instance.new("ScrollingFrame") atTargetScroll.Size=UDim2.new(1,-24,0,38)
atTargetScroll.Position=UDim2.fromOffset(12,52) atTargetScroll.BackgroundColor3=C.panel
atTargetScroll.BorderSizePixel=0 atTargetScroll.ScrollBarThickness=0
atTargetScroll.ScrollingDirection=Enum.ScrollingDirection.X
atTargetScroll.CanvasSize=UDim2.new() atTargetScroll.Parent=pAuto corner(atTargetScroll,9) tracked(atTargetScroll)
local atTargetLay=Instance.new("UIListLayout") atTargetLay.FillDirection=Enum.FillDirection.Horizontal
atTargetLay.Padding=UDim.new(0,6) atTargetLay.SortOrder=Enum.SortOrder.LayoutOrder atTargetLay.Parent=atTargetScroll
local atTargetPad=Instance.new("UIPadding") atTargetPad.PaddingLeft=UDim.new(0,6) atTargetPad.PaddingTop=UDim.new(0,6) atTargetPad.Parent=atTargetScroll

local atTarget=nil -- selected Player instance
local atTargetBtns={}

local function build_target_list()
    for _,b in ipairs(atTargetBtns) do b:Destroy() end atTargetBtns={}
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl~=LP then
            local b=Instance.new("TextButton") b.Size=UDim2.fromOffset(110,26) b.BackgroundColor3=C.cell
            b.BorderSizePixel=0 b.Font=F_BOLD b.Text=pl.DisplayName b.TextColor3=C.dim b.TextSize=10
            b.Parent=atTargetScroll corner(b,8)
            b.MouseButton1Click:Connect(function()
                atTarget=pl atLog("Target: "..pl.DisplayName.." (@"..pl.Name..")",C.cyan)
                for _,ob in ipairs(atTargetBtns) do ob.BackgroundColor3=C.cell ob.TextColor3=C.dim end
                b.BackgroundColor3=C.purple b.TextColor3=Color3.new(1,1,1)
            end)
            table.insert(atTargetBtns,b)
        end
    end
    atTargetScroll.CanvasSize=UDim2.fromOffset(atTargetLay.AbsoluteContentSize.X+12,0)
end
build_target_list()

-- item grid for auto trade (pets only by default)
local atGrid=make_grid(pAuto,134,180,atLog,true,nil)

-- Trade helpers. Adopt Me has changed TradeAPI/AddItemToOffer argument shape
-- across updates. Try the known shapes, then verify by reading my offer count
-- instead of blindly logging success when nothing was added.
local function get_trade_app_state()
    local ok,app=pcall(function() return UIManager.apps.TradeApp end)
    if not ok or not app then return nil,nil end
    local sok,state=pcall(function() return app:_get_local_trade_state() end)
    if sok and state then return app,state end
    return app,nil
end

local function my_offer_count(app)
    local ok,offer=pcall(function() return app:_get_my_offer() end)
    return (ok and offer and offer.items and #offer.items) or 0
end

local function wait_offer_increase(app,before,timeout)
    local t0=os.clock()
    repeat
        if my_offer_count(app)>before then return true end
        task.wait(0.12)
    until os.clock()-t0>timeout
    return false
end

local function add_offer_item(app,stack,unique,log_fn)
    local remote=Router.get("TradeAPI/AddItemToOffer")
    local attempts={
        {unique},
        {stack.category,unique},
        {{category=stack.category,unique=unique,item_id=stack.id,id=stack.id}},
    }
    for _,args in ipairs(attempts) do
        local before=my_offer_count(app)
        pcall(function() remote:FireServer(unpack(args)) end)
        if wait_offer_increase(app,before,1.25) then return true end
    end
    if log_fn then log_fn("Failed to add "..tostring(stack.name).." ("..tostring(unique)..")",C.red) end
    return false
end

local function picked_offer_items(grid)
    local stacks=grid.stacks()
    local out={}
    for key,n in pairs(grid.picked()) do
        local s=stacks[key]
        if s then
            for i=1,math.min(n,#s.uniques) do
                out[#out+1]={stack=s,unique=s.uniques[i]}
            end
        end
    end
    return out
end

-- auto-accept toggle
local autoAccept=false
local atAccBtn=Instance.new("TextButton") atAccBtn.Size=UDim2.new(0.5,-14,0,32)
atAccBtn.Position=UDim2.fromOffset(12,96) atAccBtn.BackgroundColor3=C.panel atAccBtn.BorderSizePixel=0
atAccBtn.Font=F_BOLD atAccBtn.Text="AUTO ACCEPT: OFF" atAccBtn.TextColor3=C.red atAccBtn.TextSize=11
atAccBtn.Parent=pAuto corner(atAccBtn,9) tracked(atAccBtn)
atAccBtn.MouseButton1Click:Connect(function()
    autoAccept=not autoAccept
    atAccBtn.Text=autoAccept and "AUTO ACCEPT: ON" or "AUTO ACCEPT: OFF"
    atAccBtn.TextColor3=autoAccept and C.green or C.red
    atLog(autoAccept and "Auto-accept enabled." or "Auto-accept disabled.",autoAccept and C.green or C.muted)
end)

-- retry on decline toggle
local autoRetry=true
local atRetryBtn=Instance.new("TextButton") atRetryBtn.Size=UDim2.new(0.5,-14,0,32)
atRetryBtn.Position=UDim2.new(0.5,2,0,96) atRetryBtn.BackgroundColor3=C.panel atRetryBtn.BorderSizePixel=0
atRetryBtn.Font=F_BOLD atRetryBtn.Text="RETRY ON DECLINE: ON" atRetryBtn.TextColor3=C.green atRetryBtn.TextSize=11
atRetryBtn.Parent=pAuto corner(atRetryBtn,9) tracked(atRetryBtn)
atRetryBtn.MouseButton1Click:Connect(function()
    autoRetry=not autoRetry
    atRetryBtn.Text=autoRetry and "RETRY ON DECLINE: ON" or "RETRY ON DECLINE: OFF"
    atRetryBtn.TextColor3=autoRetry and C.green or C.red
end)

-- start/stop button
local atRunning=false
local atStartBtn=Instance.new("TextButton") atStartBtn.Size=UDim2.new(1,-24,0,36) atStartBtn.Position=UDim2.new(0,12,1,-44)
atStartBtn.BackgroundColor3=C.green atStartBtn.BorderSizePixel=0 atStartBtn.Font=F_TITLE atStartBtn.Text="START AUTO TRADE"
atStartBtn.TextColor3=C.bg atStartBtn.TextSize=14 atStartBtn.Parent=pAuto corner(atStartBtn,10)

local tradesDone=0

local function do_auto_trade()
    if not atTarget then atLog("No target player selected.",C.red) return end
    if not atTarget.Parent then atLog("Target left the server.",C.red) return end

    local offerItems=picked_offer_items(atGrid)
    if #offerItems==0 then atLog("No items picked for the offer.",C.red) return end

    atRunning=true
    atStartBtn.Text="STOP" atStartBtn.BackgroundColor3=C.red
    atStatus.Text="AUTO TRADE - RUNNING" atStatus.TextColor3=C.green

    task.spawn(function()
        while atRunning do
            local ok,err=pcall(function()
                -- 1. Send trade request
                atLog("Sending trade request to "..atTarget.DisplayName.."...",C.cyan)
                Router.get("TradeAPI/SendTradeRequest"):FireServer(atTarget)

                -- 2. Wait for trade to open (poll TradeApp state)
                local app,state=nil,nil
                local opened=false
                for w=1,30 do
                    if not atRunning then return end
                    task.wait(1)
                    app,state=get_trade_app_state()
                    if state then opened=true atLog("Trade opened.",C.green) break end
                end
                if not opened then
                    atLog("Trade was not accepted within 30s.",C.amber)
                    if autoRetry and atRunning then
                        atLog("Retrying in 5s...",C.muted)
                        task.wait(5)
                    end
                    return
                end

                -- 3. Add items to offer
                atLog("Adding "..#offerItems.." items to offer...",C.cyan)
                local added=0
                for _,entry in ipairs(offerItems) do
                    if not atRunning then return end
                    local state2=nil
                    app,state2=get_trade_app_state()
                    if not state2 then atLog("Trade closed during item add.",C.red) return end
                    if add_offer_item(app,entry.stack,entry.unique,atLog) then added=added+1 end
                    task.wait(0.1)
                end
                atLog("Added "..added.."/"..#offerItems.." items.",added>0 and C.green or C.red)
                if added==0 then return end

                -- 4. Accept negotiation (stage 1)
                atLog("Waiting for negotiation stage...",C.cyan)
                for w=1,20 do
                    if not atRunning then return end
                    task.wait(1)
                    local state3=nil
                    app,state3=get_trade_app_state()
                    if app then pcall(function() app:_on_accept_pressed() end) end
                    app,state3=get_trade_app_state()
                    if state3 and state3.current_stage=="confirmation" then
                        atLog("Negotiation accepted. Confirmation stage.",C.green) break
                    end
                    if not state3 then atLog("Trade closed during negotiation.",C.red) return end
                end

                -- 5. Confirm trade (stage 2)
                atLog("Confirming trade...",C.cyan)
                for w=1,20 do
                    if not atRunning then return end
                    task.wait(1)
                    local state4=nil
                    app,state4=get_trade_app_state()
                    if app then pcall(function() app:_on_confirm_pressed() end) end
                    app,state4=get_trade_app_state()
                    if not state4 then
                        -- trade completed or cancelled
                        tradesDone=tradesDone+1
                        atCount.Text=tradesDone.." trades"
                        atLog("Trade #"..tradesDone.." completed.",C.green)
                        break
                    end
                end

                -- refresh inventory after trade
                task.wait(1)
                atGrid.refresh()
            end)

            if not ok then atLog("Auto trade error: "..tostring(err),C.red) end

            if not atRunning then break end
            if autoRetry and atTarget and atTarget.Parent then
                atLog("Starting next trade in 3s...",C.muted)
                task.wait(3)
            else
                break
            end
        end

        atRunning=false
        atStartBtn.Text="START AUTO TRADE" atStartBtn.BackgroundColor3=C.green
        atStatus.Text="AUTO TRADE - IDLE" atStatus.TextColor3=C.muted
        atLog("Auto trade stopped.",C.muted)
    end)
end

atStartBtn.MouseButton1Click:Connect(function()
    if atRunning then
        atRunning=false
        atLog("Stopping after current trade...",C.amber)
    else
        do_auto_trade()
    end
end)

-- auto-accept incoming trade requests (DialogApp hook)
task.spawn(function()
    task.wait(2) -- let modules load
    while gui.Parent do
        task.wait(1)
        if autoAccept then
            pcall(function()
                local da=get_dialog_app()
                if da and da.ticket_count and da.completed_ticket then
                    if da.ticket_count > da.completed_ticket then
                        da.force_response_signal:Fire(da.completed_ticket+1,table.pack("Accept"))
                        atLog("Auto-accepted incoming trade request.",C.green)
                    end
                end
            end)
        end
    end
end)


--=========================================================
-- HISTORY PAGE (3 cards per row)
--=========================================================
local histHead=Instance.new("TextLabel") histHead.Size=UDim2.new(1,-24,0,14) histHead.Position=UDim2.fromOffset(12,12)
histHead.BackgroundTransparency=1 histHead.Font=F_BODY histHead.Text="TRADE HISTORY"
histHead.TextColor3=C.muted histHead.TextSize=9 histHead.TextXAlignment=Enum.TextXAlignment.Left histHead.Parent=pHist
local histRefBtn=Instance.new("TextButton") histRefBtn.Size=UDim2.fromOffset(84,30) histRefBtn.Position=UDim2.new(1,-96,0,8)
histRefBtn.BackgroundColor3=C.panel histRefBtn.BorderSizePixel=0 histRefBtn.Font=F_BOLD histRefBtn.Text="REFRESH"
histRefBtn.TextColor3=C.cyan histRefBtn.TextSize=11 histRefBtn.Parent=pHist corner(histRefBtn,8) tracked(histRefBtn)

local histScroll=Instance.new("ScrollingFrame") histScroll.Size=UDim2.new(1,-24,1,-56) histScroll.Position=UDim2.fromOffset(12,50)
histScroll.BackgroundColor3=C.panel histScroll.BorderSizePixel=0 histScroll.ScrollBarThickness=4
histScroll.ScrollBarImageColor3=C.purple histScroll.CanvasSize=UDim2.new() histScroll.Parent=pHist
corner(histScroll,11) tracked(histScroll)
local histLay=Instance.new("UIGridLayout") histLay.CellSize=UDim2.new(0.25,-4,0,140)
histLay.CellPadding=UDim2.fromOffset(4,4) histLay.SortOrder=Enum.SortOrder.LayoutOrder histLay.Parent=histScroll
local histPad=Instance.new("UIPadding") histPad.PaddingTop=UDim.new(0,4) histPad.PaddingLeft=UDim.new(0,4)
histPad.PaddingRight=UDim.new(0,4) histPad.PaddingBottom=UDim.new(0,4) histPad.Parent=histScroll
local histStatus=Instance.new("TextLabel") histStatus.Size=UDim2.new(1,-24,1,-56) histStatus.Position=UDim2.fromOffset(12,50)
histStatus.BackgroundTransparency=1 histStatus.Font=F_BODY histStatus.Text="Tap REFRESH to load."
histStatus.TextColor3=C.muted histStatus.TextSize=12 histStatus.Parent=pHist
local histRows={}

local function item_name(entry)
    if not entry then return "?" end
    local kind=entry.id or entry.kind if not kind then return "?" end
    if ensure_kinddb() then local ok,def=pcall(function() return KindDB[kind] end)
    if ok and type(def)=="table" and def.name then return def.name end end
    return tostring(kind)
end

local function pretty_time(ts)
    if not ts then return "?" end
    local ok,dt=pcall(function() return DateTime.fromUnixTimestamp(ts) end)
    if not ok then return tostring(ts) end
    return dt:FormatLocalTime("MMM D  h:mm A","en-us")
end

local function load_history()
    histStatus.Text="Loading..." histStatus.Visible=true
    for _,r in ipairs(histRows) do r:Destroy() end histRows={}
    local ok,history=pcall(function() return Router.get("TradeAPI/GetTradeHistory"):InvokeServer() end)
    if not ok or not history then histStatus.Text="Failed to load trade history." return end
    if #history==0 then histStatus.Text="No trade history." return end
    histStatus.Visible=false
    local myId=LP.UserId
    table.sort(history,function(a,b) return (a.timestamp or 0)>(b.timestamp or 0) end)

    local SQ,GAP,ICOLS=28,2,6
    local function item_image(entry) if not entry then return "" end local def=kind_lookup(entry.id or entry.kind) return (def and def.image) or "" end
    local function group_items(items) if not items then return {} end local seen,arr={},{}
    for _,it in ipairs(items) do local id=it.id or it.kind or "?"
    if seen[id] then seen[id].count=seen[id].count+1
    else local g={id=id,image=item_image(it),name=item_name(it),count=1} seen[id]=g table.insert(arr,g) end end return arr end

    local function render_mini(parent,groups,yOff,label,col)
        local lbl=Instance.new("TextLabel") lbl.Size=UDim2.new(1,-6,0,10) lbl.Position=UDim2.fromOffset(6,yOff)
        lbl.BackgroundTransparency=1 lbl.Font=F_BOLD lbl.TextSize=8 lbl.TextColor3=col
        lbl.TextXAlignment=Enum.TextXAlignment.Left lbl.Text=label lbl.Parent=parent
        for gi,g in ipairs(groups) do if gi>ICOLS*3 then break end
        local ci=((gi-1)%ICOLS) local ri=math.floor((gi-1)/ICOLS)
        local x=6+ci*(SQ+GAP) local y=yOff+12+ri*(SQ+GAP)
        local sq=Instance.new("Frame") sq.Size=UDim2.fromOffset(SQ,SQ) sq.Position=UDim2.fromOffset(x,y)
        sq.BackgroundColor3=C.cell sq.BorderSizePixel=0 sq.Parent=parent corner(sq,5)
        local img=Instance.new("ImageLabel") img.Size=UDim2.fromOffset(SQ-4,SQ-4) img.Position=UDim2.fromOffset(2,2)
        img.BackgroundTransparency=1 img.Image=g.image img.ScaleType=Enum.ScaleType.Fit img.Parent=sq
        if g.count>1 then local badge=Instance.new("TextLabel") badge.Size=UDim2.fromOffset(18,10)
        badge.Position=UDim2.new(1,-18,0,0) badge.BackgroundColor3=C.purple badge.BorderSizePixel=0
        badge.Font=F_BOLD badge.TextSize=7 badge.TextColor3=Color3.new(1,1,1) badge.Text="x"..g.count
        badge.Parent=sq corner(badge,4) end end
    end

    for i,rec in ipairs(history) do
        local isSender=(rec.sender_user_id==myId)
        local partner=isSender and (rec.recipient_name or "?") or (rec.sender_name or "?")
        local myItems=isSender and (rec.sender_items or {}) or (rec.recipient_items or {})
        local theirItems=isSender and (rec.recipient_items or {}) or (rec.sender_items or {})
        local card=Instance.new("Frame") card.BackgroundColor3=C.card card.BorderSizePixel=0
        card.LayoutOrder=i card.Parent=histScroll card.ClipsDescendants=true corner(card,9)
        local pname=Instance.new("TextLabel") pname.Size=UDim2.new(1,-8,0,12) pname.Position=UDim2.fromOffset(6,3)
        pname.BackgroundTransparency=1 pname.Font=F_BOLD pname.TextSize=9 pname.TextColor3=C.text
        pname.TextXAlignment=Enum.TextXAlignment.Left pname.TextTruncate=Enum.TextTruncate.AtEnd
        pname.Text="@"..partner pname.Parent=card
        local tl=Instance.new("TextLabel") tl.Size=UDim2.new(1,-8,0,10) tl.Position=UDim2.fromOffset(6,15)
        tl.BackgroundTransparency=1 tl.Font=F_LOG tl.TextSize=7 tl.TextColor3=C.muted
        tl.TextXAlignment=Enum.TextXAlignment.Left tl.Text=pretty_time(rec.timestamp) tl.Parent=card
        render_mini(card,group_items(myItems),27,"GAVE",C.red)
        render_mini(card,group_items(theirItems),88,"GOT",C.green)
        table.insert(histRows,card)
    end
    task.defer(function() histScroll.CanvasSize=UDim2.fromOffset(0,histLay.AbsoluteContentSize.Y+12) end)
end
histRefBtn.MouseButton1Click:Connect(function() task.spawn(load_history) end)

--=========================================================
-- PLAYERS PAGE
--=========================================================
local plLog=make_log(pPlay,-108,80)
local plHead=Instance.new("TextLabel") plHead.Size=UDim2.new(1,-24,0,14) plHead.Position=UDim2.fromOffset(12,12)
plHead.BackgroundTransparency=1 plHead.Font=F_BODY plHead.Text="PLAYERS IN THIS SERVER"
plHead.TextColor3=C.muted plHead.TextSize=9 plHead.TextXAlignment=Enum.TextXAlignment.Left plHead.Parent=pPlay
local plCount=Instance.new("TextLabel") plCount.Size=UDim2.fromOffset(80,14) plCount.Position=UDim2.new(1,-92,0,12)
plCount.BackgroundTransparency=1 plCount.Font=F_BOLD plCount.Text="0" plCount.TextColor3=C.purple
plCount.TextSize=9 plCount.TextXAlignment=Enum.TextXAlignment.Right plCount.Parent=pPlay
local plRefBtn=Instance.new("TextButton") plRefBtn.Size=UDim2.fromOffset(84,30) plRefBtn.Position=UDim2.new(1,-96,0,30)
plRefBtn.BackgroundColor3=C.panel plRefBtn.BorderSizePixel=0 plRefBtn.Font=F_BOLD plRefBtn.Text="REFRESH"
plRefBtn.TextColor3=C.cyan plRefBtn.TextSize=11 plRefBtn.Parent=pPlay corner(plRefBtn,8) tracked(plRefBtn)
local plScroll=Instance.new("ScrollingFrame") plScroll.Size=UDim2.new(1,-24,1,-190) plScroll.Position=UDim2.fromOffset(12,68)
plScroll.BackgroundColor3=C.panel plScroll.BorderSizePixel=0 plScroll.ScrollBarThickness=4
plScroll.ScrollBarImageColor3=C.purple plScroll.CanvasSize=UDim2.new() plScroll.Parent=pPlay corner(plScroll,11) tracked(plScroll)
local plLay=Instance.new("UIListLayout") plLay.Padding=UDim.new(0,6) plLay.SortOrder=Enum.SortOrder.LayoutOrder plLay.Parent=plScroll
local plPad=Instance.new("UIPadding") plPad.PaddingTop=UDim.new(0,8) plPad.PaddingLeft=UDim.new(0,8)
plPad.PaddingRight=UDim.new(0,8) plPad.PaddingBottom=UDim.new(0,8) plPad.Parent=plScroll
local plRows={}
local function build_players()
    for _,r in ipairs(plRows) do r:Destroy() end plRows={}
    local others={} for _,pl in ipairs(Players:GetPlayers()) do if pl~=LP then table.insert(others,pl) end end
    plCount.Text=#others.." online"
    for i,pl in ipairs(others) do
        local row=Instance.new("Frame") row.Size=UDim2.new(1,0,0,54) row.BackgroundColor3=C.card
        row.BorderSizePixel=0 row.LayoutOrder=i row.Parent=plScroll corner(row,10)
        local av=Instance.new("ImageLabel") av.Size=UDim2.fromOffset(40,40) av.Position=UDim2.fromOffset(8,7)
        av.BackgroundColor3=C.cell av.BorderSizePixel=0 av.ScaleType=Enum.ScaleType.Crop av.Parent=row corner(av,8)
        task.spawn(function() local ok2,img=pcall(function() return Players:GetUserThumbnailAsync(pl.UserId,Enum.ThumbnailType.HeadShot,Enum.ThumbnailSize.Size48x48) end)
        if ok2 then av.Image=img end end)
        local dn=Instance.new("TextLabel") dn.Size=UDim2.new(1,-190,0,18) dn.Position=UDim2.fromOffset(56,8)
        dn.BackgroundTransparency=1 dn.Font=F_BOLD dn.TextSize=13 dn.TextColor3=C.text
        dn.TextXAlignment=Enum.TextXAlignment.Left dn.TextTruncate=Enum.TextTruncate.AtEnd dn.Text=pl.DisplayName dn.Parent=row
        local loc="?" if pl.Character then local par=pl.Character.Parent if par then loc=par.Name=="Workspace" and "overworld" or par.Name end else loc="loading" end
        local un=Instance.new("TextLabel") un.Size=UDim2.new(1,-190,0,14) un.Position=UDim2.fromOffset(56,26)
        un.BackgroundTransparency=1 un.Font=F_BODY un.TextSize=10 un.TextColor3=C.muted
        un.TextXAlignment=Enum.TextXAlignment.Left un.TextTruncate=Enum.TextTruncate.AtEnd
        un.Text="@"..pl.Name.."  .  "..loc un.Parent=row
        local tpBtn=Instance.new("TextButton") tpBtn.Size=UDim2.fromOffset(82,32) tpBtn.Position=UDim2.new(1,-178,0.5,-16)
        tpBtn.BackgroundColor3=C.purple tpBtn.BorderSizePixel=0 tpBtn.Font=F_BOLD tpBtn.Text="TELEPORT"
        tpBtn.TextColor3=Color3.new(1,1,1) tpBtn.TextSize=10 tpBtn.Parent=row corner(tpBtn,8)
        tpBtn.MouseButton1Click:Connect(function()
            local char=pl.Character local myChar=LP.Character
            if not char or not char:FindFirstChild("HumanoidRootPart") then plLog("@"..pl.Name.." not loaded.",C.amber) return end
            if not myChar or not myChar:FindFirstChild("HumanoidRootPart") then plLog("Your character not loaded.",C.red) return end
            pcall(function() myChar.HumanoidRootPart.CFrame=char.HumanoidRootPart.CFrame*CFrame.new(2.5,5,2.5) end)
            plLog("Teleported to "..pl.DisplayName,C.green)
        end)
        local trBtn=Instance.new("TextButton") trBtn.Size=UDim2.fromOffset(72,32) trBtn.Position=UDim2.new(1,-90,0.5,-16)
        trBtn.BackgroundColor3=C.cyan trBtn.BorderSizePixel=0 trBtn.Font=F_BOLD trBtn.Text="TRADE"
        trBtn.TextColor3=C.bg trBtn.TextSize=10 trBtn.Parent=row corner(trBtn,8)
        trBtn.MouseButton1Click:Connect(function()
            pcall(function() Router.get("TradeAPI/SendTradeRequest"):FireServer(pl) end)
            plLog("Trade request sent to "..pl.DisplayName,C.cyan)
            trBtn.Text="SENT" trBtn.BackgroundColor3=C.muted
            task.delay(4,function() trBtn.Text="TRADE" trBtn.BackgroundColor3=C.cyan end)
        end)
        table.insert(plRows,row)
    end
    plScroll.CanvasSize=UDim2.fromOffset(0,plLay.AbsoluteContentSize.Y+16)
end
plRefBtn.MouseButton1Click:Connect(function() build_players() plLog("Refreshed.",C.cyan) end)
Players.PlayerAdded:Connect(function() if pages.players.Visible then build_players() end end)
Players.PlayerRemoving:Connect(function() task.defer(function() if pages.players.Visible then build_players() end end) end)


--=========================================================
-- SETTINGS PAGE
--=========================================================
local function sHead(y,txt) local l=Instance.new("TextLabel") l.Size=UDim2.new(1,-24,0,14) l.Position=UDim2.fromOffset(14,y)
l.BackgroundTransparency=1 l.Font=F_BODY l.Text=txt l.TextColor3=C.muted l.TextSize=9 l.TextXAlignment=Enum.TextXAlignment.Left l.Parent=pSet end
local function sCard(y,h) local f=Instance.new("Frame") f.Size=UDim2.new(1,-28,0,h) f.Position=UDim2.fromOffset(14,y)
f.BackgroundColor3=C.card f.BorderSizePixel=0 f.Parent=pSet corner(f,11) tracked(f) return f end

sHead(16,"APPEARANCE")
local opCard=sCard(34,64)
local opTitle=Instance.new("TextLabel") opTitle.Size=UDim2.new(1,-100,0,18) opTitle.Position=UDim2.fromOffset(14,10)
opTitle.BackgroundTransparency=1 opTitle.Font=F_BOLD opTitle.Text="Window opacity" opTitle.TextColor3=C.text
opTitle.TextSize=13 opTitle.TextXAlignment=Enum.TextXAlignment.Left opTitle.Parent=opCard
local opVal=Instance.new("TextLabel") opVal.Size=UDim2.fromOffset(60,18) opVal.Position=UDim2.new(1,-74,0,10)
opVal.BackgroundTransparency=1 opVal.Font=F_TITLE opVal.Text="100%" opVal.TextColor3=C.purple
opVal.TextSize=13 opVal.TextXAlignment=Enum.TextXAlignment.Right opVal.Parent=opCard
local track=Instance.new("TextButton") track.Size=UDim2.new(1,-28,0,14) track.Position=UDim2.fromOffset(14,38)
track.BackgroundColor3=C.cell track.BorderSizePixel=0 track.Text="" track.AutoButtonColor=false track.Parent=opCard corner(track,7)
local fill=Instance.new("Frame") fill.Size=UDim2.fromScale(1,1) fill.BackgroundColor3=C.purple fill.BorderSizePixel=0 fill.Parent=track corner(fill,7)
local knob=Instance.new("Frame") knob.Size=UDim2.fromOffset(16,16) knob.Position=UDim2.new(1,-16,0.5,-8)
knob.BackgroundColor3=C.text knob.BorderSizePixel=0 knob.Parent=track corner(knob,8)

sHead(82,"DISPLAY")
local lgCard=sCard(100,56)
local lgTitle=Instance.new("TextLabel") lgTitle.Size=UDim2.new(1,-120,0,18) lgTitle.Position=UDim2.fromOffset(14,10)
lgTitle.BackgroundTransparency=1 lgTitle.Font=F_BOLD lgTitle.Text="Activity logs" lgTitle.TextColor3=C.text
lgTitle.TextSize=13 lgTitle.TextXAlignment=Enum.TextXAlignment.Left lgTitle.Parent=lgCard
local lgSub=Instance.new("TextLabel") lgSub.Size=UDim2.new(1,-120,0,14) lgSub.Position=UDim2.fromOffset(14,28)
lgSub.BackgroundTransparency=1 lgSub.Font=F_BODY lgSub.Text="Toggle the log panel on all tabs"
lgSub.TextColor3=C.muted lgSub.TextSize=10 lgSub.TextXAlignment=Enum.TextXAlignment.Left lgSub.Parent=lgCard
local lgBtn=Instance.new("TextButton") lgBtn.Size=UDim2.fromOffset(96,32) lgBtn.Position=UDim2.new(1,-110,0.5,-16)
lgBtn.BackgroundColor3=C.green lgBtn.BorderSizePixel=0 lgBtn.Font=F_BOLD lgBtn.Text="VISIBLE"
lgBtn.TextColor3=C.bg lgBtn.TextSize=12 lgBtn.Parent=lgCard corner(lgBtn,9)
local logsVisible=true
lgBtn.MouseButton1Click:Connect(function()
    logsVisible=not logsVisible
    lgBtn.Text=logsVisible and "VISIBLE" or "HIDDEN"
    lgBtn.BackgroundColor3=logsVisible and C.green or C.muted
    for _,pg in pairs(pages) do
        for _,child in ipairs(pg:GetChildren()) do
            if child:IsA("ScrollingFrame") and child.ScrollBarImageColor3==C.muted then child.Visible=logsVisible end
            if child:IsA("TextLabel") and child.Text=="ACTIVITY" then child.Visible=logsVisible end
        end
    end
end)

sHead(172,"SESSION")
local rjCard=sCard(190,56)
local rjTitle=Instance.new("TextLabel") rjTitle.Size=UDim2.new(1,-120,0,18) rjTitle.Position=UDim2.fromOffset(14,10)
rjTitle.BackgroundTransparency=1 rjTitle.Font=F_BOLD rjTitle.Text="Rejoin this server" rjTitle.TextColor3=C.text
rjTitle.TextSize=13 rjTitle.TextXAlignment=Enum.TextXAlignment.Left rjTitle.Parent=rjCard
local rjSub=Instance.new("TextLabel") rjSub.Size=UDim2.new(1,-120,0,14) rjSub.Position=UDim2.fromOffset(14,28)
rjSub.BackgroundTransparency=1 rjSub.Font=F_BODY rjSub.Text="Teleports back into this place"
rjSub.TextColor3=C.muted rjSub.TextSize=10 rjSub.TextXAlignment=Enum.TextXAlignment.Left rjSub.Parent=rjCard
local rjBtn=Instance.new("TextButton") rjBtn.Size=UDim2.fromOffset(96,32) rjBtn.Position=UDim2.new(1,-110,0.5,-16)
rjBtn.BackgroundColor3=C.purple rjBtn.BorderSizePixel=0 rjBtn.Font=F_TITLE rjBtn.Text="REJOIN"
rjBtn.TextColor3=Color3.new(1,1,1) rjBtn.TextSize=12 rjBtn.Parent=rjCard corner(rjBtn,9)
rjBtn.MouseButton1Click:Connect(function() pcall(function() TPS:Teleport(game.PlaceId,LP) end) end)

sHead(260,"ABOUT")
local aCard=sCard(278,100)
local aTitle=Instance.new("TextLabel") aTitle.Size=UDim2.new(1,-28,0,18) aTitle.Position=UDim2.fromOffset(14,10)
aTitle.BackgroundTransparency=1 aTitle.Font=F_BOLD aTitle.Text="LazyHub "..VERSION aTitle.TextColor3=C.text
aTitle.TextSize=13 aTitle.TextXAlignment=Enum.TextXAlignment.Left aTitle.Parent=aCard
local aBody=Instance.new("TextLabel") aBody.Size=UDim2.new(1,-28,0,64) aBody.Position=UDim2.fromOffset(14,30)
aBody.BackgroundTransparency=1 aBody.Font=F_BODY
aBody.Text="Built for lazy people who want to be even lazier. Releaser dumps pets into the recycler in one call. Trade fills your offer box instantly. Auto Trade handles the full send-accept-confirm flow on repeat. History shows your past trades visually. Players lets you teleport and trade anyone in the server."
aBody.TextColor3=C.muted aBody.TextSize=10 aBody.TextXAlignment=Enum.TextXAlignment.Left
aBody.TextYAlignment=Enum.TextYAlignment.Top aBody.TextWrapped=true aBody.Parent=aCard

local function setOpacity(a) for _,o in ipairs(FADE) do o.BackgroundTransparency=1-a end opVal.Text=math.floor(a*100).."%" end
do local dragging=false
local function upd(px) local rel=math.clamp((px-track.AbsolutePosition.X)/track.AbsoluteSize.X,0.2,1)
fill.Size=UDim2.fromScale(rel,1) knob.Position=UDim2.new(rel,-16,0.5,-8) setOpacity(rel) end
track.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=true upd(i.Position.X) end end)
UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then upd(i.Position.X) end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end end) end

--=========================================================
-- WINDOW CHROME
--=========================================================
do local dragging,sp,sa
header.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging,sp,sa=true,i.Position,root.AbsolutePosition end end)
UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then local d=i.Position-sp root.Position=UDim2.fromOffset(sa.X+d.X,sa.Y+d.Y) end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end end) end

local grip=Instance.new("TextButton") grip.Size=UDim2.fromOffset(20,20) grip.Position=UDim2.new(1,-20,1,-20)
grip.BackgroundColor3=C.cell grip.BorderSizePixel=0 grip.Text="" grip.AutoButtonColor=false grip.ZIndex=6 grip.Parent=root corner(grip,10)
local gd=Instance.new("Frame") gd.Size=UDim2.fromOffset(6,6) gd.Position=UDim2.new(0.5,-3,0.5,-3)
gd.BackgroundColor3=C.muted gd.BorderSizePixel=0 gd.ZIndex=7 gd.Parent=grip corner(gd,3)
do local rz,sp,ss
grip.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then rz,sp,ss=true,i.Position,root.AbsoluteSize end end)
UIS.InputChanged:Connect(function(i) if rz and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then local d=i.Position-sp root.Size=UDim2.fromOffset(math.max(MINW,ss.X+d.X),math.max(MINH,ss.Y+d.Y)) end end)
UIS.InputEnded:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then rz=false end end) end

local orb=Instance.new("TextButton") orb.Size=UDim2.fromOffset(56,56) orb.Position=UDim2.fromOffset(40,220)
orb.BackgroundColor3=C.purple orb.BorderSizePixel=0 orb.Text=LOGO_IMAGE and "" or "L"
orb.Font=F_TITLE orb.TextColor3=Color3.new(1,1,1) orb.TextSize=25 orb.Visible=false orb.AutoButtonColor=false
orb.Parent=gui corner(orb,28)
if LOGO_IMAGE then local oi=Instance.new("ImageLabel") oi.Size=UDim2.fromScale(1,1) oi.BackgroundTransparency=1
oi.Image=LOGO_IMAGE oi.ScaleType=Enum.ScaleType.Fit oi.Parent=orb end
do local dragging,moved,sp,sa
orb.InputBegan:Connect(function(i) if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging,moved,sp,sa=true,false,i.Position,orb.AbsolutePosition end end)
UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then local d=i.Position-sp if math.abs(d.X)+math.abs(d.Y)>6 then moved=true end orb.Position=UDim2.fromOffset(sa.X+d.X,sa.Y+d.Y) end end)
UIS.InputEnded:Connect(function(i) if (i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch) and dragging then dragging=false if not moved then orb.Visible=false root.Visible=true end end end) end
minBtn.MouseButton1Click:Connect(function() root.Visible=false orb.Visible=true end)
closeBtn.MouseButton1Click:Connect(function() gui:Destroy() end)

--=========================================================
-- RECYCLER LOGIC
--=========================================================
local function recycler_part() for _,p in ipairs(CS:GetTagged("PetRecycler")) do if p:IsDescendantOf(workspace) then return p end end return nil end
local function furniture_unique(part) local node=part while node and node.Parent do if node.Name:find("/") then return node.Name:match("([^/]+)$") end node=node.Parent end return nil end

local relBusy,relArm=false,false
fire.MouseButton1Click:Connect(function()
    if relBusy then relLog("Already running.",C.amber) return end
    local stacks=relGrid.stacks() local uniques={}
    for key,n in pairs(relGrid.picked()) do local s=stacks[key]
    if s then for i=1,math.min(n,#s.uniques) do table.insert(uniques,s.uniques[i]) end end end
    local n=#uniques if n==0 then relLog("Nothing picked.",C.amber) return end
    if not relArm then relArm=true fire.Text="TAP AGAIN TO RELEASE "..comma(n) fire.BackgroundColor3=C.red
    relLog("Ready to release "..comma(n).." pets.",C.red)
    task.delay(4,function() if relArm then relArm=false fire.Text="RELEASE" fire.BackgroundColor3=C.purple end end) return end
    relArm=false relBusy=true fire.Text="WORKING..." fire.BackgroundColor3=C.cell
    task.spawn(function() local ok2,err2=pcall(function()
        local before=get_tickets() or 0
        if not recycler_part() then relLog("Entering Nursery...",C.cyan)
        pcall(function() InteriorsM.enter_smooth("Nursery","MainDoor",{}) end)
        local w=0 while w<14 do task.wait(0.4) w=w+0.4 if recycler_part() then break end end end
        local part=recycler_part() if not part then relLog("Recycler not found.",C.red) return end
        local uf=furniture_unique(part) if not uf then relLog("Bad furniture id.",C.red) return end
        local set={} for _,u in ipairs(uniques) do set[u]=true end
        Router.get("HousingAPI/ActivateInteriorFurniture"):InvokeServer(uf,part.Name,{uniques=set},LP.Character)
        relLog("Released "..comma(n).." pets. Claiming...",C.green) relGrid.clear()
        for i=1,60 do task.wait(1)
        pcall(function() Router.get("PetRecyclerAPI/TicketsCollected"):InvokeServer() end)
        local now=get_tickets() or 0 if now>before then relLog("+"..comma(now-before).." tickets.",C.green) break end
        if i%10==0 then relLog("Waiting ("..i.."s)...",C.muted) end end
        relGrid.refresh()
    end) if not ok2 then relLog("Error: "..tostring(err2),C.red) end
    relBusy=false fire.Text="RELEASE" fire.BackgroundColor3=C.purple end)
end)

-- TRADE FILL LOGIC
local function trade_open() local app,state=get_trade_app_state() if state then return app,state end return nil end

local trBusy=false
trFire.MouseButton1Click:Connect(function()
    if trBusy then trLog("Already filling.",C.amber) return end
    if not trade_open() then trLog("No trade open.",C.amber) return end
    local offerItems=picked_offer_items(trGrid)
    if #offerItems==0 then trLog("Nothing picked.",C.amber) return end
    trBusy=true trFire.Text="FILLING..." trFire.BackgroundColor3=C.cell
    task.spawn(function() local ok2,err2=pcall(function()
        trLog("Adding "..#offerItems.." items...",C.cyan)
        local added=0
        for _,entry in ipairs(offerItems) do
            local app,state=trade_open()
            if not app then trLog("Trade closed.",C.red) break end
            if add_offer_item(app,entry.stack,entry.unique,trLog) then added=added+1 end
            task.wait(0.1)
        end
        trLog("Added "..added.."/"..#offerItems.." items.",added>0 and C.green or C.red)
        if added==#offerItems then trGrid.clear() end
    end) if not ok2 then trLog("Error: "..tostring(err2),C.red) end
    trBusy=false trFire.Text="PUT ITEMS IN TRADE" trFire.BackgroundColor3=C.cyan end)
end)

task.spawn(function() while gui.Parent do task.wait(3) if pages.trade.Visible then
if trade_open() then if not trBusy then trFire.Text="PUT ITEMS IN TRADE" trFire.BackgroundColor3=C.cyan end
elseif not trBusy then trFire.Text="OPEN A TRADE FIRST" trFire.BackgroundColor3=C.card end end end end)

--=========================================================
-- TICKET WATCHER
--=========================================================
task.spawn(function() local last=get_tickets() if last then tikVal.Text=comma(last) end
while gui.Parent do task.wait(2) local now=get_tickets()
if now then tikVal.Text=comma(now)
if last and now>last then TS:Create(tikVal,TweenInfo.new(0.12),{TextSize=18}):Play()
task.delay(0.15,function() TS:Create(tikVal,TweenInfo.new(0.25),{TextSize=14}):Play() end) end
last=now else tikVal.Text="n/a" end end end)

--=========================================================
-- AUTO-LOAD PAGES
--=========================================================
local histLoaded,plLoaded=false,false
local origShow=show
show=function(name) origShow(name)
if name=="history" and not histLoaded then histLoaded=true task.spawn(load_history) end
if name=="players" and not plLoaded then plLoaded=true build_players() end
if name=="auto" then build_target_list() end end

show("releaser")
relLog("LazyHub "..VERSION.." ready.",C.purple)
trLog("Open a trade, pick items, tap to fill.",C.dim)
atLog("Select a target player and items, then start.",C.dim)

end)  -- end bootstrap pcall

if not __ok then
    pcall(function() writefile("lazyhub_error.txt",tostring(__err)) end)
    local egui=Instance.new("ScreenGui") egui.Name="LazyHubError" egui.ResetOnSpawn=false
    egui.Parent=(gethui and gethui()) or game.Players.LocalPlayer:WaitForChild("PlayerGui")
    local f=Instance.new("Frame") f.Size=UDim2.fromOffset(420,200) f.Position=UDim2.new(0.5,-210,0.5,-100)
    f.BackgroundColor3=Color3.fromRGB(15,15,18) f.BorderSizePixel=0 f.Active=true f.Draggable=true f.Parent=egui
    local c=Instance.new("UICorner") c.CornerRadius=UDim.new(0,12) c.Parent=f
    local t=Instance.new("TextLabel") t.Size=UDim2.new(1,-24,0,24) t.Position=UDim2.fromOffset(12,10)
    t.BackgroundTransparency=1 t.Font=Enum.Font.GothamBlack t.Text="LazyHub failed to load"
    t.TextColor3=Color3.fromRGB(255,82,104) t.TextSize=16 t.TextXAlignment=Enum.TextXAlignment.Left t.Parent=f
    local m=Instance.new("TextLabel") m.Size=UDim2.new(1,-24,1,-70) m.Position=UDim2.fromOffset(12,40)
    m.BackgroundTransparency=1 m.Font=Enum.Font.Code m.Text=tostring(__err)
    m.TextColor3=Color3.fromRGB(240,242,250) m.TextSize=12 m.TextWrapped=true
    m.TextXAlignment=Enum.TextXAlignment.Left m.TextYAlignment=Enum.TextYAlignment.Top m.Parent=f
    local x=Instance.new("TextButton") x.Size=UDim2.fromOffset(80,30) x.Position=UDim2.new(1,-92,1,-38)
    x.BackgroundColor3=Color3.fromRGB(167,119,255) x.BorderSizePixel=0 x.Font=Enum.Font.GothamBold
    x.Text="CLOSE" x.TextColor3=Color3.new(1,1,1) x.TextSize=12 x.Parent=f
    local xc=Instance.new("UICorner") xc.CornerRadius=UDim.new(0,8) xc.Parent=x
    x.MouseButton1Click:Connect(function() egui:Destroy() end)
end