local Globals = {}

--[[ Annotations ]]
--- @alias TickData { Angle: EulerAngles, Position: Vector3, SimTime: number }
--- @alias PlayerHistory { Ticks: TickData[] }
--- @alias PlayerCurrent { Angle: EulerAngles, Position: Vector3, SimTime: number }
--- @alias PlayerState { Strikes: number, IsCheater: boolean }
--- @alias Globals.PlayerData table<number, { Entity: any, History: PlayerHistory, Current: PlayerCurrent, Info: PlayerState }>
Globals.PlayerData = {}

--layout of the playerdata
Globals.PlayerData = {
    {
        Entity = nil,
        Info = {
            Strikes = 0,
            IsCheater = false,
            LastDetectionDate = os.date("%Y-%m-%d %H:%M:%S"),
            LastDetectionTime = os.time(),
            Bhops = 0,
        },

        Current = {
            Angle = EulerAngles(0,0,0),
            Position = Vector3(0,0,0),
            SimTime = 0,
            LastOnGround = true,
        },

        History = {
            {
                Angle = EulerAngles(0,0,0),
                Hitboxes = {
                    Head = Vector3(0,0,0),
                    Body = Vector3(0,0,0),
                },
                SimTime = 0,
                CanJump = true
            },
        },
    }
}

--[[Shared Varaibles]]
Globals.DataBase = {}

Globals.players = {}
Globals.pLocal = nil
Globals.WLocal = nil
Globals.latin = nil
Globals.latout = nil

Globals.defaultRecord = {
    Name = "NN",
    cause = "None",
    date = os.date("%Y-%m-%d %H:%M:%S"),
}

Globals.Default_Menu = {
    Tabs = {
        Main = true,
        Visuals = false,
        playerlist = false,
    },

    Main = {
        StrikeLimit = 5,
        ChokeDetection = {
            Enable = true,
            MaxChoke = 7,
        },
        WarpDetection = {
            Enable = true,
        },
        BhopDetection = {
            Enable = true,
            MaxBhop = 2,
        },
        AimbotDetection = {
            Enable = true,
            MAXfov = 20,
        },
        AntyAimDetection = true,
        DuckSpeedDetection = true,
        debug = false,
    },

    Visuals = {
        AutoMark = true,
        partyCallaut = true,
        Chat_Prefix = true,
        Cheater_Tags = true,
        Debug = false,
    },
}

Globals.Menu = Globals.Default_Menu

return Globals