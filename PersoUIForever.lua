-- PersoUIForever.lua - v1
-- Masque la barre d'action 1 (re-affichee pour glisser-deposer, grimoire,
-- metiers, vehicule) et affiche/deplace le compteur de FPS sous la minimap.
-- Options en jeu : Options -> Interface -> Addons -> PersoUIForever.

local ADDON = "PersoUIForever"

local f = CreateFrame("Frame")
local bar
local fpsPositioned = false

-- =============================
-- Base de donnees (SavedVariables)
-- =============================
local defaults = {
    hideBar1  = true,   -- masquer la barre d'action 1
    showFps   = true,   -- afficher le compteur de FPS
    fpsX      = 0,      -- decalage X sous la minimap
    fpsY      = -18,     -- decalage Y sous la minimap
    moveSocial = false, -- deplacer le bouton Social (QuickJoinToastButton)
    socialX   = 0,       -- decalage X par rapport a sa position d'origine
    socialY   = 0,       -- decalage Y par rapport a sa position d'origine
    hideLeft  = true,    -- masquer MultiBarLeft (affichee au survol)
    hideRight = true,    -- masquer MultiBarRight (affichee au survol)
    hideBottomLeft  = true, -- masquer MultiBarBottomLeft (affichee au survol)
    hideBottomRight = true, -- masquer MultiBarBottomRight (affichee au survol)
    hideBar5  = true,    -- masquer MultiBar5 (affichee au survol)
    hideBar6  = true,    -- masquer MultiBar6 (affichee au survol)
    hideBar7  = true,    -- masquer MultiBar7 (affichee au survol)
    ccFix    = true,     -- fix des icones CC sur les nameplates
    ccScale  = 1.5,       -- echelle des icones CC
    ccGap    = 3,         -- ecart avec le badge de niveau
    stealthBar = true,   -- fix du paging de la barre 1 en furtif (voleur)
    darkBorders = true,  -- bordures des boutons en noir (dark mode)
}
local db

-- =============================
-- Logique : barre d'action 1
-- =============================
local function FindBar()
    return MainActionBar or _G["ActionBar1"]
end

local function CursorHoldsSomething()
    local ok, res = pcall(CursorHasSpell)
    if ok and res then return true end
    ok, res = pcall(CursorHasItem)
    if ok and res then return true end
    ok, res = pcall(CursorHasMacro)
    if ok and res then return true end
    ok, res = pcall(CursorHasMoney)
    if ok and res then return true end
    return false
end

local function InVehicleOrPossessed()
    local ok, res = pcall(UnitInVehicle, "player")
    if ok and res then return true end
    ok, res = pcall(UnitHasVehicleUI, "player")
    if ok and res then return true end
    ok, res = pcall(UnitControllingVehicle, "player")
    if ok and res then return true end
    return false
end

-- Le bouton "Quitter le vehicule" (MainMenuBarVehicleLeaveButton) est un
-- enfant de la barre 1 : il herite de son alpha et disparaitrait avec elle.
-- On le reloge sur UIParent pour qu'il reste visible (fin de trajet
-- griffon, arret anticipe), tout en gardant sa place a l'ecran.
local leaveBtnDetached = false
local leaveBtnVisible = false
local function DetachLeaveButton()
    if leaveBtnDetached or not bar then return end
    local btn = _G["MainMenuBarVehicleLeaveButton"]
    if not btn then return end
    local ok = pcall(function()
        -- 1) Memorise TOUTES ses ancres actuelles (position sauvegardee
        --    par le mode edition du jeu, deplacee par le joueur)
        local points = {}
        for i = 1, btn:GetNumPoints() do
            points[i] = { btn:GetPoint(i) }
        end

        -- 2) Le reloge sur UIParent (independant de l'alpha de la barre 1)
        btn:SetParent(UIParent)

        -- 3) Re-applique a l'identique ses ancres sauvegardees :
        --    il reste exactement la ou le mode edition l'a place
        btn:ClearAllPoints()
        for i, p in ipairs(points) do
            btn:SetPoint(p[1], p[2], p[3], p[4], p[5])
        end

        btn:SetAlpha(1)
        btn:Show()
    end)
    if ok then
        leaveBtnDetached = true
        -- Pretend qu'il est visible : la premiere passe de
        -- UpdateLeaveButton appliquera le masquage initial.
        leaveBtnVisible = true
        print("|cff00ff00[" .. ADDON .. "]|r Bouton Quitter le vehicule rendu autonome (position conservee).")
    end
end

-- Affiche le bouton Quitter le vehicule seulement pendant un trajet
-- (griffon/taxi) ou dans un vehicule. Sinon invisible + ignore la souris.
-- Methode par alpha : aucun Show/Hide protege, donc pas de taint en combat.
local function UpdateLeaveButton()
    if not leaveBtnDetached then return end
    local btn = _G["MainMenuBarVehicleLeaveButton"]
    if not btn then return end
    local inContext = InVehicleOrPossessed()
    if not inContext then
        local ok, res = pcall(UnitOnTaxi, "player")
        if ok and res then inContext = true end
    end
    if leaveBtnVisible == inContext then return end
    leaveBtnVisible = inContext
    btn:SetAlpha(inContext and 1 or 0)
    -- Echelle quasi nulle quand cache : plus de surface cliquable du tout
    -- (SetIgnoreMouse ne s'applique pas aux boutons securises)
    pcall(btn.SetScale, btn, inContext and 1 or 0.0001)
end

-- =============================
-- Logique : barres annexes (MultiBarLeft / MultiBarRight)
-- Masquees par defaut, affichees au survol de la souris ou quand le
-- curseur porte un skill/macro (pour pouvoir y deposer).
-- Alpha 0 : la barre reste "visible" pour la detection souris.
-- =============================
local hoverBars = {}  -- [frame] = etat initialise

-- La souris est-elle sur la barre ou l'un de ses boutons ?
-- (les boutons enfants sont des regions souris distinctes : il faut
-- les tester individuellement, sinon la barre clignote)
local function IsMouseOverBar(fr, prefix)
    if fr:IsMouseOver() then return true end
    for i = 1, 12 do
        local btn = _G[prefix .. i]
        if btn and btn.IsMouseOver and btn:IsMouseOver() then
            return true
        end
    end
    return false
end

-- Configuration des barres d'action gerees au survol :
-- frame, prefixe de ses 12 boutons, cle d'option, et
-- vehicule = true pour la barre principale (skills de quete en vehicule)
local SIDE_BARS = {
    { frame = "MainActionBar",        buttons = "ActionButton",             key = "hideBar1",        vehicle = true },
    { frame = "MultiBarLeft",         buttons = "MultiBarLeftButton",       key = "hideLeft" },
    { frame = "MultiBarRight",        buttons = "MultiBarRightButton",      key = "hideRight" },
    { frame = "MultiBarBottomLeft",   buttons = "MultiBarBottomLeftButton", key = "hideBottomLeft" },
    { frame = "MultiBarBottomRight",  buttons = "MultiBarBottomRightButton", key = "hideBottomRight" },
    { frame = "MultiBar5",            buttons = "MultiBar5Button",          key = "hideBar5" },
    { frame = "MultiBar6",            buttons = "MultiBar6Button",          key = "hideBar6" },
    { frame = "MultiBar7",            buttons = "MultiBar7Button",          key = "hideBar7" },
}

-- Applique l'etat des barres d'action.
-- ctx contient les tests partages (pickup, grimoire, metiers, vehicule),
-- calcules UNE fois par passage : le survol seul reste par barre.
local function UpdateSideBars(ctx)
    for _, entry in ipairs(SIDE_BARS) do
        local fr = _G[entry.frame]
        if not fr and entry.frame == "MainActionBar" then
            fr = FindBar()
        end
        if fr then
            if db[entry.key] then
                -- Masquee par defaut ; allume au survol (barre ou boutons),
                -- quand le curseur porte un skill/macro (pour deposer),
                -- ou quand le grimoire / les metiers sont ouverts ;
                -- la barre principale s'allume aussi en vehicule (quête)
                local show = ctx.pickup
                    or IsMouseOverBar(fr, entry.buttons)
                    or ctx.spells or ctx.profs
                if entry.vehicle and ctx.vehicle then
                    show = true
                end
                if show then
                    fr:SetAlpha(1)
                else
                    fr:SetAlpha(0)
                end
            else
                -- Option desactivee : barre toujours visible et neutre
                fr:SetAlpha(1)
            end
        end
    end
end

-- =============================
-- Logique : compteur de FPS
-- =============================
local function ApplyFpsPosition()
    local fr = _G["FramerateFrame"]
    if not fr or not _G["Minimap"] then return end
    fr:ClearAllPoints()
    fr:SetPoint("TOP", Minimap, "BOTTOM", db.fpsX, db.fpsY)
    fpsPositioned = true
end

local function ApplyFpsVisibility()
    local fr = _G["FramerateFrame"]
    if not fr then return end
    if db.showFps then
        if fr.IsShown and not fr:IsShown() then
            pcall(fr.Show, fr)
        end
        ApplyFpsPosition()
    else
        -- Option desactivee : on cache le compteur et on rend la main a Ctrl+R
        if fr.IsShown and fr:IsShown() then
            pcall(fr.Hide, fr)
        end
    end
end

-- =============================
-- Logique : bouton Social (QuickJoinToastButton)
-- =============================
-- On memorise sa position d'origine au premier acces,
-- puis on le decale selon les offsets choisis.
local socialOriginal = nil

local function ApplySocialPosition()
    local btn = _G["QuickJoinToastButton"]
    if not btn then return end

    -- Capture la position d'origine (une seule fois)
    if not socialOriginal then
        local point, relTo, relPoint, x, y = btn:GetPoint(1)
        if not point then return end
        socialOriginal = {
            point = point,
            relTo = relTo,
            relPoint = relPoint,
            x = x or 0,
            y = y or 0,
        }
    end

    if db.moveSocial then
        btn:ClearAllPoints()
        if socialOriginal.relTo then
            btn:SetPoint(socialOriginal.point, socialOriginal.relTo,
                socialOriginal.relPoint,
                socialOriginal.x + db.socialX,
                socialOriginal.y + db.socialY)
        else
            btn:SetPoint(socialOriginal.point, "UIParent",
                socialOriginal.point,
                socialOriginal.x + db.socialX,
                socialOriginal.y + db.socialY)
        end
    else
        -- Option desactivee : restaure la position d'origine
        btn:ClearAllPoints()
        if socialOriginal.relTo then
            btn:SetPoint(socialOriginal.point, socialOriginal.relTo,
                socialOriginal.relPoint, socialOriginal.x, socialOriginal.y)
        else
            btn:SetPoint(socialOriginal.point, "UIParent",
                socialOriginal.point, socialOriginal.x, socialOriginal.y)
        end
    end
end

-- =============================
-- Logique : nameplates - fix des icones de controle de foule (CC)
-- =============================
-- Place les icones CC a droite du badge de niveau et les agrandit.
-- Structure des nameplates (client Forever) :
--   UnitFrame.PlayerLevelDiffFrame             badge de niveau
--   UnitFrame.AurasFrame.CrowdControlListFrame liste des debuffs CC
--   UnitFrame.AurasFrame.LossOfControlFrame    icone d'incapacite
-- Les elements d'UI de base ne sont pas modifies ailleurs.

local ccHooked = setmetatable({}, { __mode = "k" })

-- Cible d'ancrage : le badge de niveau s'il est visible,
-- sinon le bord droit de la barre de vie
local function CCAnchorTarget(unitFrame)
    local badge = unitFrame.PlayerLevelDiffFrame
    if badge and badge:IsShown() then
        return badge, db.ccGap
    end
    return unitFrame.HealthBarsContainer, 5
end

-- Restaure la position et l'echelle par defaut des icones CC
local function RestoreCC(unitFrame)
    local auras = unitFrame.AurasFrame
    if not auras then return end
    local anchor = unitFrame.HealthBarsContainer
    local cc = auras.CrowdControlListFrame
    if cc then
        cc:SetScale(1)
        cc:ClearAllPoints()
        if anchor then
            cc:SetPoint("LEFT", anchor, "RIGHT", 5, 0)
        end
    end
    local loc = auras.LossOfControlFrame
    if loc then
        loc:SetScale(auras.auraItemScale or 1)
        loc:ClearAllPoints()
        if anchor then
            loc:SetPoint("LEFT", anchor, "RIGHT", 5, 0)
        end
    end
end

local function PlaceCC(unitFrame)
    local auras = unitFrame.AurasFrame
    if not auras then return end
    local anchor, x = CCAnchorTarget(unitFrame)
    if not anchor then return end

    -- Liste CC : Blizzard ne touche pas son echelle, on l'agrandit ici
    local cc = auras.CrowdControlListFrame
    if cc then
        local scale = db.ccScale
        cc:SetScale(scale)
        cc:ClearAllPoints()
        -- Les offsets d'un frame mis a l'echelle sont dans son
        -- propre systeme d'unites : on compense
        cc:SetPoint("LEFT", anchor, "RIGHT", x / scale, 0)
    end

    -- Icone d'incapacite : Blizzard la re-scaled a chaque maj,
    -- donc l'echelle est appliquee dans ScaleCCLoC
    local loc = auras.LossOfControlFrame
    if loc then
        local scale = (auras.auraItemScale or 1) * db.ccScale
        loc:ClearAllPoints()
        loc:SetPoint("LEFT", anchor, "RIGHT", x / scale, 0)
    end
end

-- Applique l'echelle a l'icone d'incapacite (rappelee a chaque refresh)
local function ScaleCCLoC(auras)
    local loc = auras and auras.LossOfControlFrame
    if not loc then return end
    if db and db.ccFix then
        loc:SetScale((auras.auraItemScale or 1) * db.ccScale)
    else
        loc:SetScale(auras.auraItemScale or 1)
    end
    local unitFrame = auras:GetParent()
    if unitFrame then pcall(PlaceCC, unitFrame) end
end

-- Applique le fix (ou la restauration) a une nameplate
local function ApplyCC(unitFrame)
    if db and db.ccFix then
        pcall(PlaceCC, unitFrame)
        pcall(ScaleCCLoC, unitFrame.AurasFrame)
    else
        pcall(RestoreCC, unitFrame)
    end
end

local function HookCC(unitFrame)
    if ccHooked[unitFrame] then return end
    ccHooked[unitFrame] = true

    -- Blizzard repositionne les nameplates regulierement :
    -- on re-applique apres chaque mise en page
    if unitFrame.UpdateAnchors then
        hooksecurefunc(unitFrame, "UpdateAnchors", ApplyCC)
    end

    local auras = unitFrame.AurasFrame
    if auras and auras.RefreshLossOfControl then
        hooksecurefunc(auras, "RefreshLossOfControl", function(a)
            pcall(ScaleCCLoC, a)
        end)
    end

    -- Le badge de niveau apparait/disparait : recalculer la position
    local badge = unitFrame.PlayerLevelDiffFrame
    if badge then
        badge:HookScript("OnShow", function() pcall(ApplyCC, unitFrame) end)
        badge:HookScript("OnHide", function() pcall(ApplyCC, unitFrame) end)
    end
end

local function OnPlateFrame(plate)
    if not plate or (plate.IsForbidden and plate:IsForbidden()) then return end
    local unitFrame = plate.UnitFrame
    if not unitFrame then return end
    HookCC(unitFrame)
    ApplyCC(unitFrame)
end

-- Applique le fix (ou la restauration) a toutes les nameplates actives
local function ApplyCCToAllPlates()
    local ok, plates = pcall(C_NamePlate.GetNamePlates)
    if not ok then return end
    for _, plate in ipairs(plates or {}) do
        if plate.UnitFrame and not (plate.IsForbidden and plate:IsForbidden()) then
            ApplyCC(plate.UnitFrame)
        end
    end
end

local ccFrame = CreateFrame("Frame")
ccFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
ccFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
ccFrame:SetScript("OnEvent", function(_, event, unit)
    if not db then return end
    if event == "NAME_PLATE_UNIT_ADDED" then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
        if ok then OnPlateFrame(plate) end
    else
        ApplyCCToAllPlates()
    end
end)

-- =============================
-- Logique : fix du paging de la barre 1 en furtif (voleur)
-- =============================
-- Le bug : la barre d'action 1 ne change pas de page quand le voleur
-- passe en furtif. Le fix force la page des boutons ActionButton1-12
-- via un controleur securise (fonctionne meme en combat).
-- Le reste (vehicule, override, possess, mort...) reste a Blizzard.

local stealthInstalled = false
local stealthController = nil
local stealthIsRogue = false

-- Etat "stealth" -> page 7 (barre bonus voleur) ; sinon retour au natif
local STEALTH_SNIPPET = [[
    local page
    if newstate == "stealth" then
        page = 7 -- premiere barre bonus : furtif du voleur
    end
    for index = 1, 12 do
        local button = self:GetFrameRef("button" .. index)
        if button:GetAttribute("actionpage") ~= page then
            button:SetAttribute("actionpage", page)
        end
    end
]]

local function InstallStealthBar()
    if stealthInstalled or InCombatLockdown() or not db then return end
    if not db.stealthBar or not stealthIsRogue then return end
    -- Attend que la barre 1 et ses 12 boutons existent
    if not MainActionBar then return end
    for index = 1, 12 do
        if not _G["ActionButton" .. index] then return end
    end

    local controller = CreateFrame("Frame", nil, UIParent,
        "SecureHandlerStateTemplate")
    for index = 1, 12 do
        controller:SetFrameRef("button" .. index, _G["ActionButton" .. index])
    end
    controller:SetAttribute("_onstate-page", STEALTH_SNIPPET)
    -- "native" est l'etat par defaut du driver : seule la condition
    -- [stealth] a besoin d'etre distinguee
    RegisterStateDriver(controller, "page", "[stealth] stealth; native")

    stealthController = controller
    stealthInstalled = true
    print("|cff00ff00[" .. ADDON .. "]|r Fix de la barre furtif actif.")
end

local function UninstallStealthBar()
    if not stealthInstalled or InCombatLockdown() then return end
    -- Retire le driver et rend ses pages natives aux 12 boutons
    pcall(UnregisterStateDriver, stealthController, "page")
    pcall(stealthController.Execute, stealthController, [[
        for index = 1, 12 do
            local button = self:GetFrameRef("button" .. index)
            button:SetAttribute("actionpage", nil)
        end
    ]])
    stealthController:Hide()
    stealthController = nil
    stealthInstalled = false
    print("|cffffd200[" .. ADDON .. "]|r Fix de la barre furtif desactive.")
end

-- =============================
-- Logique : dark mode - bordures des boutons en noir
-- =============================
-- Teinte la texture "Normal" de chaque bouton d'action (c'est elle qui
-- dessine la bordure) en noir. Re-applique a chaque passage car le
-- client recree ces textures quand une action change de slot.

local function UpdateDarkBorders()
    local prefixes = { "ActionButton" }
    for _, entry in ipairs(SIDE_BARS) do
        if entry.buttons ~= "ActionButton" then
            prefixes[#prefixes + 1] = entry.buttons
        end
    end
    -- Boutons de bijoux du ForeverTrinketMenu (s'ils existent :
    -- test a chaque passage, aucun acces si l'addon est absent)
    prefixes[#prefixes + 1] = "ForeverTrinketMenuSlot"

    -- Barre de posture/stance (voleur, guerrier, druide...) :
    -- ignoree proprement pour les classes qui n'en ont pas
    prefixes[#prefixes + 1] = "StanceButton"

    for _, prefix in ipairs(prefixes) do
        local maxButtons = 12
        if prefix == "ForeverTrinketMenuSlot" then
            maxButtons = 2
        elseif prefix == "StanceButton" then
            maxButtons = 6
        end
        for i = 1, maxButtons do
            local btn = _G[prefix .. i]
            if btn and btn.GetNormalTexture then
                local tex = btn:GetNormalTexture()
                if tex then
                    if db.darkBorders then
                        tex:SetVertexColor(0, 0, 0)
                    else
                        tex:SetVertexColor(1, 1, 1)
                    end
                end
            end
        end
    end

    -- Boutons ItemRack (IRFButton13/14) : ignores si l'addon n'est pas
    -- installe ou si ces boutons n'ont pas ete ajoutes a l'interface
    for _, name in ipairs({ "IRFButton13", "IRFButton14" }) do
        local btn = _G[name]
        if btn and btn.GetNormalTexture then
            local tex = btn:GetNormalTexture()
            if tex then
                if db.darkBorders then
                    tex:SetVertexColor(0, 0, 0)
                else
                    tex:SetVertexColor(1, 1, 1)
                end
            end
        end
    end
end

-- =============================
-- Boucle principale (cadencee a 10 passages par seconde : largement
-- suffisant pour un survol, et divise la charge CPU par ~6 par
-- rapport a un passage par frame)
-- =============================
local TICK = 0.1
local elapsedAcc = 0
local mainWatcher = CreateFrame("Frame")
mainWatcher:SetScript("OnUpdate", function(self, elapsed)
    elapsedAcc = elapsedAcc + elapsed
    if elapsedAcc < TICK then return end
    elapsedAcc = 0

    -- Trouve la barre 1 des qu'elle existe (message unique)
    if not bar then
        local b = FindBar()
        if b then
            bar = b
            DetachLeaveButton()
            print("|cff00ff00[" .. ADDON .. "]|r Barre d'action 1 geree comme les barres annexes.")
        end
    end

    if not db then return end

    -- FPS : applique visibilite + position (au chargement, sans Ctrl+R)
    ApplyFpsVisibility()

    -- Bouton Social : REPOSITIONNE a chaque passage (comme avant
    -- l'optimisation) pour contrer les repositionnements du client
    -- (furtif, combat) ; a 10 passages/s le cout est negligeable.
    ApplySocialPosition()

    -- Bouton "Quitter le vehicule" : relance la recuperation tant
    -- qu'elle n'a pas reussi (le bouton peut naitre plus tard),
    -- puis gere sa visibilite (visible seulement en trajet/vehicule)
    DetachLeaveButton()

    -- Tests partages : calcules UNE fois, utilises par toutes les barres.
    -- Pas de cache de position souris (GetMousePosition peu fiable sur
    -- ce client) : le survol est reevalue a chaque passage, comme avant.
    local spells = _G["PlayerSpellsFrame"]
    local profs = _G["ProfessionsFrame"]
    local ctx = {
        pickup  = CursorHoldsSomething(),
        spells  = spells and spells:IsShown() or false,
        profs   = profs and profs:IsShown() or false,
        vehicle = InVehicleOrPossessed(),
    }
    UpdateLeaveButton()
    UpdateSideBars(ctx)
    UpdateDarkBorders()

    -- Fix furtif : tente l'installation tant qu'elle n'a pas reussi
    -- (barre/boutons pas encore crees, ou combat en cours) ;
    -- desinstalle proprement si l'option a ete decochee
    if db then
        if stealthIsRogue and db.stealthBar then
            InstallStealthBar()
        elseif stealthInstalled then
            UninstallStealthBar()
        end
    end
end)

-- =============================
-- Interface d'options en jeu
-- =============================
local function BuildOptions()
    local panel = CreateFrame("Frame", ADDON .. "OptionsPanel")
    panel.name = ADDON

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText(ADDON)

    -- Fenetre a taille fixe avec defilement vertical
    local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -48)
    scroll:SetPoint("BOTTOMRIGHT", -12, 12)

    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(620)
    scroll:SetScrollChild(content)

    -- Titre de section (paragraphe) : toujours aligne a gauche
    -- sur le bord du contenu, sans decalage herite des widgets
    local function MakeSection(anchor, text)
        local h = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        h:SetPoint("TOP", anchor, "BOTTOM", 0, -28)
        h:SetPoint("LEFT", content, "LEFT", 0, 0)
        h:SetText(text)
        local line = content:CreateTexture(nil, "OVERLAY")
        line:SetColorTexture(0.4, 0.4, 0.4, 0.5)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -4)
        line:SetPoint("RIGHT", content, "RIGHT", 0, 0)
        return h
    end

    -- Fabrique une case a cocher (template selon disponibilite du client)
    local function MakeCheckbox(anchor, text, tooltip, get, set)
        local cb
        local ok = pcall(function()
            cb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
        end)
        if not ok or not cb then
            cb = CreateFrame("CheckButton", nil, content, "SettingsCheckBoxTemplate")
        end
        cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
        local label = cb:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("LEFT", cb, "RIGHT", 6, 1)
        label:SetText(text)
        cb.tooltipText = tooltip
        cb:SetChecked(get())
        cb:SetScript("OnClick", function(self)
            set(self:GetChecked())
            self:SetChecked(get())
        end)
        return cb
    end

    -- Fabrique un curseur de valeur (step optionnel, par defaut 1 ;
    -- un step < 1 autorise les valeurs decimales, ex. 0.1)
    local function MakeSlider(anchor, text, minV, maxV, get, set, step)
        step = step or 1
        local s
        local ok = pcall(function()
            s = CreateFrame("Slider", nil, content, "OptionsSliderTemplate")
        end)
        if not ok or not s then
            s = CreateFrame("Slider", nil, content)
        end
        s:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 10, -24)
        s:SetMinMaxValues(minV, maxV)
        s:SetValueStep(step)
        s:SetObeyStepOnDrag(true)
        s:SetWidth(220)

        local label = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        label:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 2)
        label:SetText(text)

        local val = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        val:SetPoint("LEFT", s, "RIGHT", 10, 0)
        local function fmt(v)
            if step < 1 then
                return string.format("%.1f", v)
            end
            return tostring(math.floor(v + 0.5))
        end
        val:SetText(fmt(get()))

        s:SetValue(get())
        s:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v / step + 0.5) * step
            set(v)
            val:SetText(fmt(get()))
        end)
        return s
    end

    -- Point de depart du contenu defilant
    local top = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    top:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -4)
    top:SetText("Configuration de l'interface - v1")

    -- ==========================================
    -- Section 1 : Barres d'action (visibles au survol)
    -- ==========================================
    local sec1 = MakeSection(top, "Barres d'actions")
    local cbBar = MakeCheckbox(
        sec1,
        "Masquer la barre d'action 1 (visible en véhicule de quete)",
        "Masque la barre 1 par defaut. Elle s'affiche au survol de la souris, au glisser-deposer d'un skill/macro, a l'ouverture du grimoire ou des metiers, et automatiquement en vehicule de quete.",
        function() return db.hideBar1 end,
        function(v) db.hideBar1 = v end
    )

    -- Barres annexes (dans la meme section "Barres d'actions")
    local cbLeft = MakeCheckbox(
        cbBar,
        "Masquer MultiBarLeft (visible au survol de la souris)",
        "Masque la barre annexe gauche par defaut. Elle s'affiche quand la souris la survole ou quand le curseur porte un skill/macro.",
        function() return db.hideLeft end,
        function(v) db.hideLeft = v end
    )
    local cbRight = MakeCheckbox(
        cbLeft,
        "Masquer MultiBarRight (visible au survol de la souris)",
        "Masque la barre annexe droite par defaut. Elle s'affiche quand la souris la survole ou quand le curseur porte un skill/macro.",
        function() return db.hideRight end,
        function(v) db.hideRight = v end
    )
    local cbBottomLeft = MakeCheckbox(
        cbRight,
        "Masquer MultiBarBottomLeft (visible au survol de la souris)",
        "Masque la barre en bas a gauche par defaut. Elle s'affiche au survol, au glisser-deposer, ou avec le grimoire/les metiers.",
        function() return db.hideBottomLeft end,
        function(v) db.hideBottomLeft = v end
    )
    local cbBottomRight = MakeCheckbox(
        cbBottomLeft,
        "Masquer MultiBarBottomRight (visible au survol de la souris)",
        "Masque la barre en bas a droite par defaut. Elle s'affiche au survol, au glisser-deposer, ou avec le grimoire/les metiers.",
        function() return db.hideBottomRight end,
        function(v) db.hideBottomRight = v end
    )
    local cbBar5 = MakeCheckbox(
        cbBottomRight,
        "Masquer MultiBar5 (visible au survol de la souris)",
        "Masque la barre 5 par defaut. Elle s'affiche au survol, au glisser-deposer, ou avec le grimoire/les metiers.",
        function() return db.hideBar5 end,
        function(v) db.hideBar5 = v end
    )
    local cbBar6 = MakeCheckbox(
        cbBar5,
        "Masquer MultiBar6 (visible au survol de la souris)",
        "Masque la barre 6 par defaut. Elle s'affiche au survol, au glisser-deposer, ou avec le grimoire/les metiers.",
        function() return db.hideBar6 end,
        function(v) db.hideBar6 = v end
    )
    local cbBar7 = MakeCheckbox(
        cbBar6,
        "Masquer MultiBar7 (visible au survol de la souris)",
        "Masque la barre 7 par defaut. Elle s'affiche au survol, au glisser-deposer, ou avec le grimoire/les metiers.",
        function() return db.hideBar7 end,
        function(v) db.hideBar7 = v end
    )
    local cbDark = MakeCheckbox(
        cbBar7,
        "Dark mode : bordures des boutons en noir",
        "Met en noir les bordures des boutons de toutes les barres d'action. Desactive : bordures d'origine du client.",
        function() return db.darkBorders end,
        function(v) db.darkBorders = v end
    )

    -- ==========================================
    -- Section 2 : Compteur de FPS
    -- ==========================================
    local sec2 = MakeSection(cbDark, "Compteur de FPS")
    local cbFps = MakeCheckbox(
        sec2,
        "Afficher le compteur de FPS sous la minimap",
        "Affiche le compteur de FPS en dessous de la minimap, au chargement du jeu, sans Ctrl+R.",
        function() return db.showFps end,
        function(v)
            db.showFps = v
            ApplyFpsVisibility()
        end
    )
    local sliderX = MakeSlider(
        cbFps,
        "Position X du compteur de FPS", -200, 200,
        function() return db.fpsX end,
        function(v)
            db.fpsX = v
            fpsPositioned = false
            ApplyFpsVisibility()
        end
    )
    local sliderY = MakeSlider(
        sliderX,
        "Position Y du compteur de FPS", -300, 50,
        function() return db.fpsY end,
        function(v)
            db.fpsY = v
            fpsPositioned = false
            ApplyFpsVisibility()
        end
    )

    -- ==========================================
    -- Section 3 : Bouton Social
    -- ==========================================
    local sec3 = MakeSection(sliderY, "Bouton Social")
    local cbSocial = MakeCheckbox(
        sec3,
        "Deplacer le bouton Social (QuickJoinToastButton)",
        "Active le deplacement du bouton Social au-dessus de la fenetre de chat. Desactive, il garde sa position d'origine.",
        function() return db.moveSocial end,
        function(v) db.moveSocial = v end
    )
    local sliderSocialX = MakeSlider(
        cbSocial,
        "Position X du bouton Social", -400, 400,
        function() return db.socialX end,
        function(v) db.socialX = v end
    )
    local sliderSocialY = MakeSlider(
        sliderSocialX,
        "Position Y du bouton Social", -400, 400,
        function() return db.socialY end,
        function(v) db.socialY = v end
    )

    -- ==========================================
    -- Section 4 : Nameplates - icones CC
    -- ==========================================
    local sec4 = MakeSection(sliderSocialY, "Nameplates - icones de controle de foule (CC)")
    local cbCC = MakeCheckbox(
        sec4,
        "Activer le fix des icones CC sur les nameplates",
        "Place les icones de controle de foule (CC) a droite du badge de niveau des nameplates et les agrandit. Desactive : position et taille d'origine du client.",
        function() return db.ccFix end,
        function(v)
            db.ccFix = v
            ApplyCCToAllPlates()
        end
    )
    local sliderCCScale = MakeSlider(
        cbCC,
        "Echelle des icones CC", 1.0, 4.0,
        function() return db.ccScale end,
        function(v)
            db.ccScale = v
            ApplyCCToAllPlates()
        end,
        0.1
    )
    local sliderCCGap = MakeSlider(
        sliderCCScale,
        "Ecart avec le badge de niveau", 0, 20,
        function() return db.ccGap end,
        function(v)
            db.ccGap = v
            ApplyCCToAllPlates()
        end
    )

    -- ==========================================
    -- Section 5 : Barre furtif (voleur)
    -- ==========================================
    local sec5 = MakeSection(sliderCCGap, "Barre furtif (voleur)")
    local cbStealth = MakeCheckbox(
        sec5,
        "Corriger le changement de barre en furtif",
        "Force la page de la barre d'action 1 sur la barre bonus furtif quand le voleur passe camoufle (fonctionne en combat). Desactive : comportement natif du client. Sans effet sur les autres classes.",
        function() return db.stealthBar end,
        function(v) db.stealthBar = v end
    )

    -- Hauteur du contenu defilant : jusqu'au dernier widget + marge
    content:SetHeight(1150)

    -- Enregistrement dans les options d'addons (API selon le client)
    local ok1 = pcall(InterfaceOptions_AddCategory, panel)
    if ok1 then
        print("|cff00ff00[" .. ADDON .. "]|r Panneau d'options enregistre (InterfaceOptions).")
        return
    end
    -- API moderne (Dragonflight et +) : canvas layout + categorie addon
    local ok2 = pcall(function()
        local category = Settings.RegisterCanvasLayoutCategory(panel, ADDON, ADDON)
        category.ID = ADDON
        Settings.RegisterAddOnCategory(category)
    end)
    if ok2 then
        print("|cff00ff00[" .. ADDON .. "]|r Panneau d'options enregistre (Settings).")
        return
    end
    print("|cffff0000[" .. ADDON .. "]|r Echec de l'enregistrement du panneau d'options.")
end

-- =============================
-- Initialisation
-- =============================
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        PersoUIForeverDB = PersoUIForeverDB or {}
        db = PersoUIForeverDB
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        -- Le fix furtif ne concerne que les voleurs (verifie une seule fois)
        local _, class = UnitClass("player")
        stealthIsRogue = (class == "ROGUE")
        BuildOptions()
        print("|cff00ff00[" .. ADDON .. "]|r v1 charge.")
    end
end)
