@echo off

node bundle.js

set "targetDir=%localappdata%\lua"
if not exist "%targetDir%" (
	mkdir "%targetDir%"
)

move /Y "Cheater_Detection.lua" "%targetDir%\Cheater_Detection.lua"
exit