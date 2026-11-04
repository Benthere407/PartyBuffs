--[[
* PartyBuffs buff groups
*
* Name-based classification used by the "Hide Job Abilities" and "Monster Debuffs Only"
* buttons on the Filters tab. Matching is done against the game's own buff names
* (case-, spacing- and punctuation-insensitive), so it does not depend on buff IDs.
*
* This is a hand-curated list. If a buff is misclassified, just add/remove its name below
* (names are matched exactly after normalizing, e.g. "Fighter's Roll" == "fighters roll").
--]]

local groups = {};

local function norm(s)
    return (tostring(s):lower():gsub('[^%w]', ''));
end

local function make_set(list)
    local set = {};
    for _,name in ipairs(list) do
        set[norm(name)] = true;
    end
    return set;
end

local function matches(name, exact, suffixes, prefixes)
    local n = norm(name);
    if exact[n] then
        return true;
    end
    for _,suffix in ipairs(suffixes) do
        if (#n > #suffix) and (n:sub(-#suffix) == suffix) then
            return true;
        end
    end
    for _,prefix in ipairs(prefixes) do
        if (n:sub(1, #prefix) == prefix) then
            return true;
        end
    end
    return false;
end

----------------------------------------------------------------------------------------------------
-- Job ability buffs (effects gained from job abilities / 2-hours / roll / maneuver / dance etc.)
----------------------------------------------------------------------------------------------------
local JA_EXACT = make_set({
    -- WAR
    'Berserk', 'Defender', 'Aggressor', 'Warcry', 'Retaliation', 'Restraint', 'Blood Rage',
    "Warrior's Charge", 'Mighty Strikes',
    -- MNK
    'Boost', 'Focus', 'Dodge', 'Counterstance', 'Impetus', 'Footwork', 'Mantra', 'Formless Strikes',
    'Inner Strength', 'Perfect Counter', 'Hundred Fists',
    -- WHM
    'Divine Seal', 'Divine Caress', 'Afflatus Solace', 'Afflatus Misery', 'Asylum', 'Benediction',
    -- BLM
    'Elemental Seal', 'Manafont', 'Mana Wall', 'Subtle Sorcery', 'Cascade', 'Manawell',
    -- RDM
    'Composure', 'Saboteur', 'Spontaneity', 'Chainspell', 'Stymie',
    -- THF
    'Sneak Attack', 'Trick Attack', 'Hide', 'Feint', 'Conspirator', "Assassin's Charge",
    'Accomplice', 'Collaborator', 'Flee', 'Perfect Dodge',
    -- PLD
    'Sentinel', 'Holy Circle', 'Rampart', 'Fealty', 'Cover', 'Divine Emblem', 'Palisade', 'Majesty',
    'Invincible',
    -- DRK
    'Last Resort', 'Souleater', 'Arcane Circle', 'Dark Seal', 'Nether Void', 'Scarlet Delirium',
    'Consume Mana',
    -- BST
    'Familiar', 'Killer Instinct', 'Spur', 'Unleash',
    -- BRD
    'Nightingale', 'Troubadour', 'Soul Voice', 'Marcato', 'Clarion Call', 'Pianissimo', 'Tenuto',
    -- RNG
    'Sharpshot', 'Barrage', 'Double Shot', 'Camouflage', 'Decoy Shot', 'Unlimited Shot',
    'Flashy Shot', 'Stealth Shot', 'Overkill', 'Hover Shot',
    -- SAM
    'Hasso', 'Seigan', 'Third Eye', 'Meikyo Shisui', 'Sekkanoki', 'Warding Circle', 'Yaegasumi',
    'Sengikori', 'Konzen-ittai',
    -- NIN
    'Yonin', 'Innin', 'Futae', 'Issekigan', 'Sange', 'Mijin Gakure',
    -- DRG
    'Ancient Circle', 'Spirit Surge', 'Dragon Breaker', 'Spirit Link', 'Fly High', 'Deep Breathing',
    -- SMN
    'Astral Flow', 'Apogee', "Avatar's Favor", 'Mana Cede',
    -- BLU
    'Burst Affinity', 'Chain Affinity', 'Efflux', 'Diffusion', 'Unbridled Learning', 'Azure Lore',
    'Convergence', 'Unbridled Wisdom',
    -- COR
    'Double-Up Chance', 'Snake Eye', 'Fold', 'Triple Shot', 'Crooked Cards',
    -- PUP
    'Overdrive', 'Overload',
    -- DNC
    'Fan Dance', 'Saber Dance', 'Trance', 'Presto', 'Contradance', 'Closed Position', 'Grand Pas',
    'No Foot Rise',
    -- SCH
    'Light Arts', 'Dark Arts', 'Addendum: White', 'Addendum: Black', 'Penury', 'Parsimony',
    'Celerity', 'Alacrity', 'Rapture', 'Ebullience', 'Accession', 'Manifestation', 'Perpetuance',
    'Immanence', 'Sublimation: Activated', 'Sublimation: Complete', 'Enlightenment', 'Stormsurge',
    -- GEO
    'Bolster', 'Lasting Emanation', 'Ecliptic Attrition', 'Life Cycle', 'Blaze of Glory',
    'Dematerialize', 'Theurgic Focus', 'Concentric Pulse', 'Mending Aura', 'Radial Arcana',
    'Full Circle', 'Collimated Fervor',
    -- RUN
    'Elemental Sforzo', 'Liement', 'Battuta', 'Valiance', 'Vallation', 'Swordplay', 'Pflug',
    'Embolden', 'Vivacious Pulse', 'One for All',
    'Ignis', 'Gelus', 'Flabra', 'Tellus', 'Sulpor', 'Unda', 'Lux', 'Tenebrae',
});
local JA_SUFFIXES = { 'roll', 'maneuver', 'samba', 'flourish' };   -- Phantom Rolls, Maneuvers, Sambas, Flourishes
local JA_PREFIXES = { 'finishingmove' };                            -- Finishing Move 1-5

----------------------------------------------------------------------------------------------------
-- Debuffs / enfeebles that monsters can inflict
----------------------------------------------------------------------------------------------------
local MON_EXACT = make_set({
    'Sleep', 'Poison', 'Paralysis', 'Blindness', 'Silence', 'Petrification', 'Disease', 'Curse',
    'Stun', 'Bind', 'Weight', 'Slow', 'Charm', 'Doom', 'Amnesia', 'Plague', 'Virus', 'Terror',
    'Gradual Petrification', 'Flash', 'Inhibit TP', 'Encumbrance',
    -- elemental DoTs
    'Burn', 'Frost', 'Choke', 'Rasp', 'Shock', 'Drown', 'Dia', 'Bio',
});
local MON_SUFFIXES = { 'down' };   -- STR Down ... CHR Down, Accuracy/Attack/Evasion/Defense Down, Max HP/MP Down, Magic * Down
local MON_PREFIXES = {};

groups.is_job_ability = function(name)
    return matches(name, JA_EXACT, JA_SUFFIXES, JA_PREFIXES);
end

groups.is_monster_debuff = function(name)
    return matches(name, MON_EXACT, MON_SUFFIXES, MON_PREFIXES);
end

return groups;
