--an system with a list of evidences and a list of evidences that are currently active
--the evidence is stored in databse/playerdata.lua
--the evidence is stored in a table with the key being the steamid
--the evidence for each posible cause is in stack
--for aimbot for bhop etc
--[[
    the evidence system assigns weight of evidence to plaegyr upon detection
    and it decays over time if not exeedign certan treshold and getign amrked as cheater
    eahc plaeyr has its own evidence table
    each has individual stacks for each detection method
    and each detection method has its own records of detection
    the scores of each record is added to the total then decayed every second or game tick 
        the total of all totals is the suspicion score of player
        idk waht is the threshold we should deem plaeyr a cheater

]]

local Evidence = {}
