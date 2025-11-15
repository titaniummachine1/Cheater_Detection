@echo off

node bundle.js

set "targetDir=%localappdata%\lua"
if not exist "%targetDir%" (
	mkdir "%targetDir%"
)

if exist "Cheater_Detection.lua" (
	move /Y "Cheater_Detection.lua" "%targetDir%\Cheater_Detection.lua"
) else (
	echo [BundleAndDeploy] No local Cheater_Detection.lua to move. Assuming bundle.js deployed directly.
)

exit