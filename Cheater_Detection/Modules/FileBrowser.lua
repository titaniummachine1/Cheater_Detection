--[[
    File browser for ImMenu
    Author: github.com/lnx00

    ImMenu Styles:
    - FileBrowser_ListSize: number
]]

---@type ImMenu
local ImMenu = require("ImMenu")

---@alias ImFile { name: string, attributes: FFileAttribute }

local currentPath = "./"
local currentOffset = 1

---@param path string
---@return ImFile[]
local function GetFileList(path)
    local files = {}

    pcall(function()
        filesystem.EnumerateDirectory(path .. "*", function (filename, attributes)
            if filename == "." or filename == ".." then return end
            table.insert(files, { name = filename, attributes = attributes })
        end)
    end)

    return files
end

---@return string|nil selectedFile
function ImMenu.FileBrowser()
    local selectedFile = nil
    local listSize = ImMenu.GetStyle()["FileBrowser_ListSize"] or 10

    if ImMenu.Begin("File Browser", true) then
        local fileList = GetFileList(currentPath)
        local fileCount = #fileList

        -- Navigation bar
        ImMenu.BeginFrame(ImAlign.Horizontal)
            ImMenu.Text("Path: " .. currentPath)
        ImMenu.EndFrame()

        -- Content
        ImMenu.BeginFrame(ImAlign.Horizontal)

            -- Navigation
            ImMenu.PushStyle("ItemSize", { 25, 75 })
            ImMenu.BeginFrame(ImAlign.Vertical)

            if ImMenu.Button("^") then
                currentOffset = math.max(currentOffset - 1, 1)
            end

            if ImMenu.Button("<") then
                currentPath = currentPath:match("(.*/).*/") or "./"
            end

            if ImMenu.Button("v") then
                currentOffset = math.clamp(currentOffset + 1, 1, fileCount - listSize + 1)
            end

            ImMenu.EndFrame()
            ImMenu.PopStyle()

            -- File list
            ImMenu.PushStyle("ItemSize", { 300, 25 })
            ImMenu.BeginFrame(ImAlign.Vertical)

            if fileCount == 0 then
                ImMenu.Text("No files found")
            end

            for i = currentOffset, currentOffset + listSize - 1 do
                local file = fileList[i]
                if file then
                    local isFolder = file.attributes == FILE_ATTRIBUTE_DIRECTORY
                    if isFolder then
                        -- Folder button
                        if ImMenu.Button(file.name .. "/") then
                            if isFolder then
                                currentPath = currentPath .. file.name .. "/"
                                currentOffset = 1
                            end
                        end
                    else
                        -- File button
                        if ImMenu.Button(file.name) then
                            selectedFile = currentPath .. file.name
                        end
                    end
                end
            end

            ImMenu.EndFrame()
            ImMenu.PopStyle()

        ImMenu.EndFrame()

        ImMenu.End()
    end

    return selectedFile
end